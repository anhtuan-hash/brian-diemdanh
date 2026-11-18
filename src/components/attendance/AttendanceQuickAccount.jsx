import React, { useRef, useState } from 'react';
import { ATTENDANCE_PERMISSION_IDS } from '../../utils/permissions.js';
import { generateStrongPassword } from '../../utils/usernameAccounts.js';

export default function AttendanceQuickAccount({ client, sections, onCreated, onClose }) {
  const [fullName, setFullName] = useState('');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState(() => generateStrongPassword(16));
  const [permissions, setPermissions] = useState([ATTENDANCE_PERMISSION_IDS.calendar, ATTENDANCE_PERMISSION_IDS.history]);
  const [created, setCreated] = useState(null);
  const [error, setError] = useState('');
  const [copyStatus, setCopyStatus] = useState('');
  const [saving, setSaving] = useState(false);
  const inFlight = useRef(false);

  async function create(event) {
    event.preventDefault();
    if (inFlight.current) return;
    setError('');
    const login = username.trim().toLowerCase();
    if (!fullName.trim()) return setError('Vui lòng nhập họ và tên.');
    if (!/^[a-z0-9][a-z0-9._-]{1,30}[a-z0-9]$/.test(login)) {
      return setError('Tên đăng nhập cần 3–32 ký tự, dùng chữ không dấu, số, dấu chấm, gạch ngang hoặc gạch dưới. Bắt đầu và kết thúc bằng chữ hoặc số.');
    }
    if (password.length < 8 || new TextEncoder().encode(password).length > 72) {
      return setError('Mật khẩu cần ít nhất 8 ký tự. Hãy dùng mật khẩu ngắn hơn hoặc bấm Tạo mật khẩu khác.');
    }
    if (!permissions.length) return setError('Hãy chọn ít nhất một quyền Điểm danh.');

    inFlight.current = true;
    setSaving(true);
    try {
      const { data, error: createError } = await client.functions.invoke('attendance-quick-account', {
        body: { fullName: fullName.trim(), username: login, password, permissions },
      });
      if (createError) {
        const details = await createError.context?.json?.().catch(() => null);
        throw new Error(details?.message || 'Chưa kết nối được dịch vụ tạo tài khoản. Vui lòng thử lại.');
      }
      if (!data?.account?.id) throw new Error('Chưa xác nhận được tài khoản mới. Hãy tải lại danh sách.');
      setCreated({ username: login, password });
      setPassword('');
      onCreated(data.account);
    } catch (failure) {
      setError(failure.message || 'Chưa tạo được tài khoản. Vui lòng thử lại.');
    } finally {
      inFlight.current = false;
      setSaving(false);
    }
  }

  async function copyCredentials() {
    try {
      await navigator.clipboard.writeText(`Tên đăng nhập: ${created.username}\nMật khẩu: ${created.password}`);
      setCopyStatus('Đã sao chép thông tin đăng nhập.');
    } catch {
      setCopyStatus('Hãy chọn và sao chép thông tin đăng nhập bên trên.');
    }
  }

  return (
    <section id="attendance-quick-account" className="attendance-quick-account" aria-labelledby="attendance-quick-account-title">
      <h2 id="attendance-quick-account-title">Tạo tài khoản nhanh</h2>
      {created ? (
        <>
          <p role="status" className="attendance-account__notice">Đã tạo tài khoản và cấp quyền Điểm danh.</p>
          <dl className="attendance-quick-account__credentials">
            <div><dt>Tên đăng nhập</dt><dd><code>{created.username}</code></dd></div>
            <div><dt>Mật khẩu</dt><dd><code>{created.password}</code></dd></div>
          </dl>
          <p>Mật khẩu hiển thị đến khi đóng mục này.</p>
          <div className="attendance-quick-account__actions">
            <button type="button" className="attendance-account__action" onClick={copyCredentials}>Sao chép thông tin đăng nhập</button>
            <button type="button" className="attendance-account__action" data-variant="outline" onClick={onClose}>Đóng</button>
          </div>
          <p role="status">{copyStatus}</p>
        </>
      ) : (
        <form onSubmit={create} autoComplete="off">
          <fieldset disabled={saving}>
            <div className="attendance-quick-account__fields">
              <label>Họ và tên
                <input value={fullName} onChange={(event) => setFullName(event.target.value)} maxLength={120} required />
              </label>
              <label>Tên đăng nhập
                <input value={username} onChange={(event) => setUsername(event.target.value)} maxLength={32}
                  placeholder="Ví dụ gv001" autoCapitalize="none" spellCheck={false} required />
              </label>
              <div className="attendance-quick-account__password">
                <label>Mật khẩu
                  <input value={password} onChange={(event) => setPassword(event.target.value)} minLength={8} maxLength={72}
                    autoComplete="new-password" autoCapitalize="none" spellCheck={false} required />
                </label>
                <button type="button" className="attendance-account__action" data-variant="outline"
                  onClick={() => setPassword(generateStrongPassword(16))}>Tạo mật khẩu khác</button>
              </div>
            </div>
            <fieldset className="attendance-quick-account__permissions">
              <legend>Quyền Điểm danh</legend>
              {sections.map(({ id, titleVi }) => (
                <label key={id} className="attendance-permissions__option">
                  <input type="checkbox" checked={permissions.includes(id)} onChange={(event) => {
                    const checked = event.target.checked;
                    setPermissions((current) => checked ? [...current, id] : current.filter((permission) => permission !== id));
                  }} />
                  <span>{id === ATTENDANCE_PERMISSION_IDS.delete ? 'Kho lưu trữ' : titleVi}</span>
                </label>
              ))}
            </fieldset>
          </fieldset>
          {error && <p role="alert" className="attendance-account__error">{error}</p>}
          <div className="attendance-quick-account__actions">
            <button type="submit" className="attendance-account__action" disabled={saving}>{saving ? 'Đang tạo…' : 'Tạo tài khoản'}</button>
            <button type="button" className="attendance-account__action" data-variant="outline" disabled={saving} onClick={onClose}>Hủy</button>
          </div>
        </form>
      )}
    </section>
  );
}
