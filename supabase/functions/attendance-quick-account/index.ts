import { createClient } from 'npm:@supabase/supabase-js@2.110.1';

const headers = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Cache-Control': 'no-store',
};
const knownPermissions = new Set([
  'attendance:quick', 'attendance:calendar', 'attendance:manage', 'attendance:history',
  'attendance:report', 'attendance:supplemental', 'attendance:delete',
]);

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...headers, 'Content-Type': 'application/json; charset=utf-8' },
  });
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (request.method !== 'POST') return json({ message: 'Phương thức không được hỗ trợ.' }, 405);

  const token = request.headers.get('Authorization')?.match(/^Bearer ([^\s]+)$/i)?.[1];
  if (!token) return json({ message: 'Vui lòng đăng nhập lại.' }, 401);

  const url = Deno.env.get('SUPABASE_URL');
  const publicKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !publicKey || !serviceKey) return json({ message: 'Dịch vụ tạo tài khoản chưa sẵn sàng.' }, 503);
  const authOptions = { persistSession: false, autoRefreshToken: false };
  const callerClient = createClient(url, publicKey, {
    auth: authOptions,
    global: { headers: { Authorization: `Bearer ${token}` } },
  });

  const { data: auth, error: authError } = await callerClient.auth.getUser(token);
  if (authError || !auth.user) return json({ message: 'Phiên đăng nhập không hợp lệ. Vui lòng đăng nhập lại.' }, 401);

  const { data: admin, error: adminError } = await callerClient.from('profiles')
    .select('role,approved,attendance_mfa_required')
    .eq('id', auth.user.id)
    .maybeSingle();
  if (adminError) return json({ message: 'Chưa kiểm tra được quyền tạo tài khoản. Vui lòng thử lại.' }, 503);
  if (admin?.role !== 'admin' || admin.approved !== true) {
    return json({ message: 'Chỉ quản trị viên đã được duyệt mới có thể tạo tài khoản.' }, 403);
  }
  if (admin.attendance_mfa_required !== false) {
    const { data: verified, error } = await callerClient.auth.getClaims(token);
    if (error || verified?.claims.sub !== auth.user.id || verified.claims.aal !== 'aal2') {
      return json({ message: 'Hãy xác thực hai yếu tố trước khi tạo tài khoản.' }, 403);
    }
  }

  const payload = await request.json().catch(() => null);
  const fullName = typeof payload?.fullName === 'string' ? payload.fullName.trim() : '';
  const username = typeof payload?.username === 'string' ? payload.username.trim().toLowerCase() : '';
  const password = typeof payload?.password === 'string' ? payload.password : '';
  const permissions: unknown = payload?.permissions;
  if (!fullName || fullName.length > 120) return json({ message: 'Họ và tên cần từ 1 đến 120 ký tự.' }, 400);
  if (!/^[a-z0-9][a-z0-9._-]{1,30}[a-z0-9]$/.test(username)) {
    return json({ message: 'Tên đăng nhập cần 3–32 ký tự hợp lệ và bắt đầu, kết thúc bằng chữ hoặc số.' }, 400);
  }
  if (password.length < 8 || new TextEncoder().encode(password).length > 72) {
    return json({ message: 'Mật khẩu cần ít nhất 8 ký tự và tối đa 72 byte.' }, 400);
  }
  if (!Array.isArray(permissions) || !permissions.length || permissions.length > knownPermissions.size
    || permissions.some((id) => typeof id !== 'string' || !knownPermissions.has(id))) {
    return json({ message: 'Hãy chọn ít nhất một quyền Điểm danh hợp lệ.' }, 400);
  }

  const selectedPermissions = [...new Set<string>(permissions)].sort();
  const email = `${username}@accounts.brianenglish.studio`;
  const adminClient = createClient(url, serviceKey, { auth: authOptions });
  const { data: created, error: createError } = await adminClient.auth.admin.createUser({
    email, password, email_confirm: true,
    app_metadata: { attendance_created_by: auth.user.id },
    user_metadata: { username, full_name: fullName, auth_mode: 'username', must_change_password: false },
  });
  if (createError || !created.user) {
    if (createError?.code === 'email_exists' || createError?.code === 'user_already_exists') {
      return json({ message: 'Tên đăng nhập này đã được sử dụng.' }, 409);
    }
    if (createError?.code === 'weak_password') {
      return json({ message: 'Mật khẩu chưa đạt yêu cầu. Hãy tạo mật khẩu mới.' }, 400);
    }
    console.error('attendance-quick-account: auth creation failed', createError?.code);
    return json({ message: 'Chưa tạo được tài khoản đăng nhập. Vui lòng thử lại.' }, 502);
  }

  const accountId = created.user.id;
  const provision = () => callerClient.rpc('bes_provision_attendance_account', {
    p_account: accountId,
    p_username: username,
    p_full_name: fullName,
    p_permissions: selectedPermissions,
  });
  const first = await provision();
  // A lost response can be retried with the same newly created Auth user ID.
  const saved = first.error && !first.error.code ? await provision() : first;
  if (!saved.error && saved.data?.id === accountId) return json({ account: saved.data }, 201);

  // A definite transaction rejection cannot have approved the new Auth user.
  const code = first.error?.code;
  if (code && ['22023', '23505', '42501', 'P0002'].includes(code)) {
    const { error: cleanupError } = await adminClient.auth.admin.deleteUser(accountId);
    if (!cleanupError) {
      if (code === '23505') return json({ message: 'Tên đăng nhập này đã được sử dụng.' }, 409);
      if (code === '42501') return json({ message: 'Quyền tạo tài khoản đã thay đổi. Vui lòng đăng nhập lại.' }, 403);
      return json({ message: 'Chưa lưu được hồ sơ. Vui lòng thử lại.' }, 502);
    }
  }
  console.error('attendance-quick-account: profile creation remains unconfirmed', saved.error?.code);
  return json({ message: 'Chưa xác nhận được hồ sơ. Hãy tải lại danh sách trước khi thử lại.' }, 502);
});
