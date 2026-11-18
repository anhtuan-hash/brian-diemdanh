import React, { useState } from 'react';
import AttendanceEditorialHeading from '../components/attendance/AttendanceEditorialHeading.jsx';
import { changeCurrentPassword } from '../utils/auth.js';
import './AttendanceAccountEditorial.css';

const errorMessages = new Map([
  ['invalid_credentials', 'Mật khẩu hiện tại không đúng.'],
  ['current_password_mismatch', 'Mật khẩu hiện tại không đúng.'],
  ['same_password', 'Mật khẩu mới phải khác mật khẩu hiện tại.'],
  ['weak_password', 'Mật khẩu mới chưa đáp ứng yêu cầu bảo mật. Hãy chọn mật khẩu khác.'],
  ['reauthentication_needed', 'Vui lòng đăng nhập lại để xác nhận danh tính rồi đổi mật khẩu.'],
  ['session_expired', 'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.'],
  ['session_not_found', 'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.'],
  ['over_request_rate_limit', 'Bạn đã gửi quá nhiều yêu cầu. Vui lòng thử lại sau ít phút.'],
]);

const saveError = 'Chưa đổi được mật khẩu. Vui lòng thử lại.';

export default function AttendanceTeacherSettings() {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  async function savePassword(event) {
    event.preventDefault();
    if (saving) return;
    const form = event.currentTarget;
    const fields = new FormData(form);
    const currentPassword = fields.get('currentPassword');
    const newPassword = fields.get('newPassword');

    setError('');
    setNotice('');
    if (newPassword === currentPassword) {
      setError(errorMessages.get('same_password'));
      return;
    }
    if (newPassword !== fields.get('confirmPassword')) {
      setError('Xác nhận mật khẩu mới chưa khớp.');
      return;
    }

    setSaving(true);
    try {
      const result = await changeCurrentPassword({ currentPassword, newPassword });
      if (!result.ok) {
        setError(errorMessages.get(result.code) || saveError);
        return;
      }
      form.reset();
      setNotice('Đã đổi mật khẩu. Hãy dùng mật khẩu mới cho lần đăng nhập tiếp theo.');
    } catch {
      setError(saveError);
    } finally {
      setSaving(false);
    }
  }

  return (
    <section className="attendance-account-security" aria-labelledby="attendance-settings-title">
      <AttendanceEditorialHeading title="Cài đặt tài khoản" titleId="attendance-settings-title" />
      <div className="attendance-account-security__setting">
        <div><h2 id="attendance-password-title">Đổi mật khẩu</h2></div>
        <form className="attendance-password-form" aria-labelledby="attendance-password-title" onSubmit={savePassword}>
          <label>
            Mật khẩu hiện tại
            <input name="currentPassword" type="password" autoComplete="current-password" required />
          </label>
          <label>
            Mật khẩu mới
            <input name="newPassword" type="password" autoComplete="new-password" minLength={8}
              aria-describedby="attendance-new-password-hint" required />
            <small id="attendance-new-password-hint">Ít nhất 8 ký tự.</small>
          </label>
          <label>
            Xác nhận mật khẩu mới
            <input name="confirmPassword" type="password" autoComplete="new-password" required />
          </label>
          <button type="submit" className="attendance-account__action" disabled={saving}>
            {saving ? 'Đang lưu…' : 'Lưu mật khẩu mới'}
          </button>
          {error && <p role="alert" className="attendance-account__error">{error}</p>}
          {notice && <p role="status" className="attendance-account__notice">{notice}</p>}
        </form>
      </div>
    </section>
  );
}
