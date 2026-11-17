import React, { useState } from 'react';
import { getRuntimeClient } from '../services/runtime/core.js';
import { initializeAuthSession } from '../utils/auth.js';
import AttendanceEditorialHeading from '../components/attendance/AttendanceEditorialHeading.jsx';
import './AttendanceAccountEditorial.css';

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
    <section className="attendance-account-security" aria-labelledby="attendance-security-title">
      <AttendanceEditorialHeading title="Bảo mật tài khoản" titleId="attendance-security-title" />
      <div className="attendance-account-security__setting">
        <div>
          <h2>Xác thực hai yếu tố</h2>
          <span className="attendance-account-security__status" data-enabled={String(Boolean(required))}>
            {required ? 'Đang bật' : 'Đang tắt'}
          </span>
        </div>
        <div>
          <p>{required
            ? 'Tài khoản quản trị viên dùng mật khẩu và mã từ ứng dụng xác thực để đăng nhập BRIAN Điểm danh.'
            : 'Tài khoản quản trị viên hiện dùng mật khẩu để đăng nhập BRIAN Điểm danh.'}</p>
          <button type="button" className="attendance-account__action" data-variant={required ? 'outline' : 'primary'}
            disabled={saving} onClick={updateRequirement}>
            {saving ? 'Đang lưu…' : required ? 'Tắt xác thực hai yếu tố' : 'Bật xác thực hai yếu tố'}
          </button>
          {error && <p role="alert" className="attendance-account__error">{error}</p>}
          {notice && <p role="status" className="attendance-account__notice">{notice}</p>}
        </div>
      </div>
    </section>
  );
}
