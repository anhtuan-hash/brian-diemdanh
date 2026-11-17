import React, { useState } from 'react';
import { getRuntimeClient } from '../services/runtime/core.js';
import { initializeAuthSession } from '../utils/auth.js';

export default function AttendanceAdminSecurity({ required }) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  async function updateRequirement() {
    const next = !required;
    setSaving(true);
    setError('');
    setNotice('');
    try {
      const { error: saveError } = await getRuntimeClient().rpc('bes_set_own_attendance_mfa', { p_required: next });
      if (saveError) throw saveError;
      const refreshed = await initializeAuthSession({ force: true });
      if (refreshed?.attendanceMfaRequired !== next) {
        setError('Đã lưu trên máy chủ. Tải lại trang để cập nhật trạng thái.');
        return;
      }
      setNotice(next ? 'Đã bật xác thực hai yếu tố.' : 'Đã tắt yêu cầu xác thực hai yếu tố.');
    } catch (saveError) {
      setError(saveError?.message || 'Chưa cập nhật được thiết lập.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <section className="bes-mfa-settings" aria-labelledby="attendance-security-title" style={{ maxWidth: 680, margin: '24px auto' }}>
      <header className="bes-mfa-settings-head">
        <h1 id="attendance-security-title">Bảo mật tài khoản</h1>
        <strong className={required ? 'enabled' : 'disabled'}>{required ? 'Đang bật' : 'Đang tắt'}</strong>
      </header>
      <p>Khi tắt, tài khoản Admin này dùng mật khẩu để đăng nhập Brian Điểm danh. Thầy có thể bật lại bất cứ lúc nào.</p>
      <div className="bes-mfa-actions">
        <button type="button" disabled={saving} onClick={updateRequirement}>
          {saving ? 'Đang lưu…' : required ? 'Tắt xác thực hai yếu tố' : 'Bật xác thực hai yếu tố'}
        </button>
      </div>
      {error && <p role="alert" className="bes-mfa-warning">{error}</p>}
      {notice && <p role="status" className="bes-mfa-feedback">{notice}</p>}
    </section>
  );
}
