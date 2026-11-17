import React, { useEffect, useState } from 'react';
import {
  consumeAuthNotice,
  isAuthConfigured,
  loginUser,
  registerTeacher,
  requestPasswordReset,
  updatePassword,
} from '../utils/auth.js';
import AttendanceLoginFooter from '../components/attendance/AttendanceLoginFooter.jsx';
import './AttendanceAuth.css';

export default function AuthPage({ mode = 'login', language, onLogin, setGlobalLoading }) {
  const isRegister = mode === 'register';
  const configured = isAuthConfigured();
  const [form, setForm] = useState({ name: '', school: '', email: '', password: '', confirm: '' });
  const [msg, setMsg] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [submitLoading, setSubmitLoading] = useState(false);
  const [recoveryMode, setRecoveryMode] = useState(
    () => window.location.href.includes('recovery=1') || window.location.href.includes('type=recovery'),
  );

  useEffect(() => {
    const detectRecovery = () => {
      const href = window.location.href || '';
      setRecoveryMode(href.includes('recovery=1') || href.includes('type=recovery'));
    };
    detectRecovery();
    window.addEventListener('hashchange', detectRecovery);
    return () => window.removeEventListener('hashchange', detectRecovery);
  }, []);

  useEffect(() => {
    const notice = consumeAuthNotice();
    if (!notice?.message) return;
    if (notice.tone === 'success') setOkMsg(notice.message);
    else setMsg(notice.message);
  }, []);

  const runPrimaryAction = async (loadingMessage, action) => {
    setSubmitLoading(true);
    setGlobalLoading?.(true, loadingMessage);
    try {
      return await action();
    } catch (error) {
      return {
        ok: false,
        message: error instanceof Error ? error.message : String(error || 'Authentication failed.'),
      };
    } finally {
      setSubmitLoading(false);
      setGlobalLoading?.(false);
    }
  };

  const submit = async (event) => {
    event.preventDefault();
    setMsg('');
    setOkMsg('');

    if (!configured) {
      setMsg(language === 'vi'
        ? 'Chưa cấu hình Supabase. Vui lòng thêm VITE_SUPABASE_URL và VITE_SUPABASE_ANON_KEY trong Vercel.'
        : 'Supabase is not configured. Add VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in Vercel.');
      return;
    }

    if (recoveryMode) {
      if (!form.password || !form.confirm) {
        setMsg(language === 'vi' ? 'Vui lòng nhập và xác nhận mật khẩu mới.' : 'Please enter and confirm your new password.');
        return;
      }
      if (form.password.length < 8) {
        setMsg(language === 'vi' ? 'Mật khẩu nên có ít nhất 8 kí tự.' : 'Password should contain at least 8 characters.');
        return;
      }
      if (form.password !== form.confirm) {
        setMsg(language === 'vi' ? 'Mật khẩu xác nhận không khớp.' : 'Passwords do not match.');
        return;
      }

      const res = await runPrimaryAction(
        language === 'vi' ? 'Đang cập nhật mật khẩu...' : 'Updating password...',
        () => updatePassword(form.password),
      );

      if (!res.ok) {
        setMsg(language === 'vi' ? translateLoginError(res.message) : res.message);
        return;
      }

      setOkMsg(language === 'vi' ? 'Đã cập nhật mật khẩu. Thầy/cô có thể đăng nhập lại.' : 'Password updated. You can sign in again.');
      setRecoveryMode(false);
      setForm((previous) => ({ ...previous, password: '', confirm: '' }));
      window.location.hash = '#/login';
      return;
    }

    if (isRegister) {
      if (!form.name || !form.school || !form.email || !form.password) {
        setMsg(language === 'vi' ? 'Vui lòng điền đầy đủ thông tin.' : 'Please complete all fields.');
        return;
      }
      if (form.password.length < 8) {
        setMsg(language === 'vi' ? 'Mật khẩu nên có ít nhất 8 kí tự.' : 'Password should contain at least 8 characters.');
        return;
      }
      if (form.password !== form.confirm) {
        setMsg(language === 'vi' ? 'Mật khẩu xác nhận không khớp.' : 'Passwords do not match.');
        return;
      }

      const res = await runPrimaryAction(
        language === 'vi' ? 'Đang tạo tài khoản...' : 'Creating account...',
        () => registerTeacher(form),
      );

      if (!res.ok) {
        setMsg(res.message || (language === 'vi' ? 'Không thể tạo tài khoản.' : 'Could not create account.'));
        return;
      }
      if (res.needsEmailConfirmation) {
        setOkMsg(language === 'vi'
          ? 'Tài khoản đã được tạo. Vui lòng kiểm tra email để xác nhận. Sau đó admin cần duyệt tài khoản trước khi sử dụng.'
          : 'Account created. Please check your email to confirm. An admin must approve the account before first use.');
        return;
      }
      if (res.pendingApproval) {
        setOkMsg(language === 'vi'
          ? 'Tài khoản đã được tạo và đang chờ admin duyệt. Sau khi được duyệt, thầy/cô đăng nhập lại để dùng app.'
          : 'Account created and waiting for admin approval. After approval, sign in again to use the app.');
        return;
      }
      if (res.user) onLogin?.(res.user);
      return;
    }

    if (!form.email || !form.password) {
      setMsg(language === 'vi' ? 'Vui lòng nhập tên đăng nhập hoặc email và mật khẩu.' : 'Please enter your username or email and password.');
      return;
    }

    const res = await runPrimaryAction(
      language === 'vi' ? 'Đang đăng nhập...' : 'Signing in...',
      () => loginUser(form),
    );

    if (!res.ok) {
      setMsg(language === 'vi' ? translateLoginError(res.message) : res.message);
      return;
    }

    onLogin?.(res.user);
  };

  const resetPassword = async () => {
    setMsg('');
    setOkMsg('');

    if (!form.email) {
      setMsg(language === 'vi' ? 'Nhập email trước khi yêu cầu đặt lại mật khẩu.' : 'Enter your email before requesting a password reset.');
      return;
    }

    setGlobalLoading?.(true, language === 'vi' ? 'Đang gửi email đặt lại mật khẩu...' : 'Sending password reset email...');
    const res = await requestPasswordReset(form.email);
    setGlobalLoading?.(false);

    if (!res.ok) {
      setMsg(res.message || (language === 'vi' ? 'Không thể gửi email đặt lại mật khẩu.' : 'Could not send reset email.'));
      return;
    }

    setOkMsg(language === 'vi' ? 'Đã gửi email đặt lại mật khẩu nếu tài khoản tồn tại.' : 'Password reset email sent if the account exists.');
  };

  const vi = language === 'vi';
  const isLogin = !recoveryMode && !isRegister;
  const title = recoveryMode
    ? (vi ? 'Đặt lại mật khẩu' : 'Reset password')
    : (vi ? 'Tạo tài khoản' : 'Create account');
  const loginTitle = vi ? 'Đăng nhập' : 'Sign in';
  const submitLabel = recoveryMode
    ? (vi ? 'Cập nhật mật khẩu' : 'Update password')
    : isRegister
      ? (vi ? 'Tạo tài khoản' : 'Create account')
      : loginTitle;
  const updateField = (event) => {
    const { name, value } = event.target;
    setForm((previous) => ({ ...previous, [name]: value }));
  };

  return (
    <div className="attendance-auth">
      <header className="attendance-auth-masthead">
        <a className="attendance-auth-brand" href="#/attendance">
          <span className="attendance-brand-mark" aria-hidden="true">
            <img src="/brian-english-brand-logo.png" alt="" width="940" height="760" />
          </span>
          <span>@brianverse</span>
        </a>
      </header>

      <main className={`attendance-auth-main${isLogin ? '' : ' attendance-auth-main--account'}`}>
        <h1 id="attendance-auth-title">
          {isLogin ? <>{loginTitle}{' '}<span>{vi ? 'giáo viên' : 'for teachers'}</span></> : title}
        </h1>

        <form id="teacher-login-form" className="attendance-auth-form" aria-labelledby="attendance-auth-title" onSubmit={submit}>
          {isRegister && !recoveryMode && (
            <>
              <div className="attendance-auth-field">
                <label htmlFor="auth-name">{vi ? 'Họ và tên' : 'Full name'}</label>
                <input id="auth-name" name="name" value={form.name} onChange={updateField}
                  autoComplete="name" placeholder={vi ? 'Nhập họ và tên' : 'Enter full name'} />
              </div>
              <div className="attendance-auth-field">
                <label htmlFor="auth-school">{vi ? 'Trường / Trung tâm' : 'School / Center'}</label>
                <input id="auth-school" name="school" value={form.school} onChange={updateField}
                  autoComplete="organization" placeholder={vi ? 'Nhập trường hoặc trung tâm' : 'Enter school or center'} />
              </div>
            </>
          )}

          {!recoveryMode && (
            <div className="attendance-auth-field">
              <label htmlFor="auth-email">{isRegister ? 'Email' : vi ? 'Tên đăng nhập hoặc email' : 'Username or email'}</label>
              <input id="auth-email" name="email" type={isRegister ? 'email' : 'text'}
                value={form.email} onChange={updateField} autoComplete={isRegister ? 'email' : 'username'}
                autoCapitalize="none" spellCheck={false}
                placeholder={isRegister
                  ? (vi ? 'ten@truong.edu.vn' : 'name@school.edu')
                  : (vi ? 'Ví dụ: gv001' : 'Example: gv001')} />
            </div>
          )}

          <div className="attendance-auth-field">
            <div className="attendance-auth-label-row">
              <label htmlFor="auth-password">
                {recoveryMode ? (vi ? 'Mật khẩu mới' : 'New password') : (vi ? 'Mật khẩu' : 'Password')}
              </label>
              {isLogin && configured && (
                <button className="attendance-auth-link" type="button" onClick={resetPassword}>
                  {vi ? 'Quên mật khẩu?' : 'Forgot password?'}
                </button>
              )}
            </div>
            <div className="attendance-auth-secret">
              <input id="auth-password" name="password" type={showPassword ? 'text' : 'password'}
                value={form.password} onChange={updateField} autoComplete={isLogin ? 'current-password' : 'new-password'}
                placeholder={vi ? 'Nhập mật khẩu' : 'Enter password'} />
              <button type="button" className="attendance-auth-toggle"
                aria-controls="auth-password"
                aria-label={showPassword ? (vi ? 'Ẩn mật khẩu' : 'Hide password') : (vi ? 'Hiện mật khẩu' : 'Show password')}
                onClick={() => setShowPassword((visible) => !visible)}>
                {showPassword ? (vi ? 'Ẩn' : 'Hide') : (vi ? 'Hiện' : 'Show')}
              </button>
            </div>
          </div>

          {!isLogin && (
            <div className="attendance-auth-field">
              <label htmlFor="auth-confirm">{vi ? 'Xác nhận mật khẩu' : 'Confirm password'}</label>
              <input id="auth-confirm" name="confirm" type="password" value={form.confirm} onChange={updateField}
                autoComplete="new-password" placeholder={vi ? 'Nhập lại mật khẩu' : 'Confirm password'} />
            </div>
          )}

          {msg && <p role="alert" className="attendance-auth-message attendance-auth-message--error">{msg}</p>}
          {okMsg && <p role="status" className="attendance-auth-message">{okMsg}</p>}

          <button className="attendance-auth-submit" type="submit" disabled={submitLoading} aria-busy={submitLoading}>
            <span>{submitLoading ? (vi ? 'Đang xử lý…' : 'Working…') : submitLabel}</span>
            <svg width="30" height="24" viewBox="0 0 30 24" fill="none" stroke="currentColor" strokeWidth="2"
              aria-hidden="true">
              <path d="M1 12h26M19 4l8 8-8 8" />
            </svg>
          </button>
        </form>

        <p className="attendance-auth-secondary">
          {isLogin ? (
            <>{vi ? 'Chưa có tài khoản?' : 'New here?'}{' '}
              <a className="attendance-auth-link" href="#/register">{vi ? 'Tạo tài khoản' : 'Create account'}</a>
            </>
          ) : (
            <a className="attendance-auth-link" href="#/login" onClick={() => setRecoveryMode(false)}>
              {vi ? 'Quay lại đăng nhập' : 'Back to sign in'}
            </a>
          )}
        </p>
      </main>
      {isLogin && <AttendanceLoginFooter />}
    </div>
  );
}

function translateLoginError(message = '') {
  const text = String(message || '').toLowerCase();
  if (text.includes('invalid login')) return 'Sai email hoặc mật khẩu.';
  if (text.includes('email not confirmed')) return 'Email chưa được xác nhận. Vui lòng kiểm tra hộp thư.';
  if (text.includes('waiting for approval') || text.includes('disabled')) return 'Tài khoản đang chờ duyệt hoặc đã bị khóa.';
  if (text.includes('recovery session')) return 'Không tìm thấy phiên đặt lại mật khẩu. Vui lòng mở lại link mới nhất trong email.';
  return message || 'Không thể đăng nhập.';
}
