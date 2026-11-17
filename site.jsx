import React, { useEffect, useRef, useState } from 'react';
import AdminMfaSecurity from './src/components/AdminMfaSecurity.jsx';
import AttendanceWorkspace from './src/pages/AttendanceWorkspace.jsx';
import AttendancePermissions from './src/pages/AttendancePermissions.jsx';
import AttendanceAdminSecurity from './src/pages/AttendanceAdminSecurity.jsx';
import AuthPage from './src/pages/AuthPage.jsx';
import { bootRuntimeCore } from './src/services/runtime/core.js';
import { useRuntimeCore } from './src/services/runtime/useRuntimeCore.js';
import { withAttendanceReadOnlyAccess } from './src/utils/attendanceReadonlyAccess.js';
import { initializeAuthSession, logoutUser } from './src/utils/auth.js';
import { hasRouteAccess } from './src/utils/permissions.js';
import { installUsernameAuthBridge } from './src/utils/usernameAccounts.js';
import './src/supplementalLearningRouteBootstrap.js';

installUsernameAuthBridge();

function readRoute() {
  const { hash, href } = window.location;
  if (href.includes('type=recovery') || href.includes('recovery=1')) return 'login';
  if (/^#\/register(?:$|\?)/.test(hash)) return 'register';
  if (hash === '#/phan-quyen') return 'permissions';
  if (hash === '#/bao-mat') return 'security';
  return 'attendance';
}

export default function AttendanceSite() {
  const runtime = useRuntimeCore();
  const [route, setRoute] = useState(readRoute);
  const [signOutError, setSignOutError] = useState(false);
  const attendanceHash = useRef(
    /^#\/(?:attendance|phan-quyen|bao-mat)(?:$|\?)/.test(window.location.hash) ? window.location.hash : '#/attendance',
  );
  const user = runtime.profile;
  const admin = user?.role === 'admin';
  const accountNames = String(user?.name || '').trim().split(/\s+/).filter(Boolean);
  const accountInitials = (accountNames[0]?.[0] || '') + (accountNames.length > 1 ? accountNames.at(-1)[0] : '');
  const isSignedIn = user?.provider === 'supabase' && user.approved === true;
  const showLogin = !isSignedIn || route === 'login';
  const canAccess = isSignedIn && hasRouteAccess(withAttendanceReadOnlyAccess(user), 'attendance');
  const adminPage = route === 'permissions' || route === 'security';

  useEffect(() => {
    const syncRoute = () => setRoute(readRoute());
    window.addEventListener('hashchange', syncRoute);
    return () => window.removeEventListener('hashchange', syncRoute);
  }, []);

  useEffect(() => {
    if (!isSignedIn) return undefined;
    const refresh = () => { void initializeAuthSession({ force: true }).catch(() => {}); };
    window.addEventListener('focus', refresh);
    return () => window.removeEventListener('focus', refresh);
  }, [isSignedIn, user?.id]);

  async function handleLogout() {
    setSignOutError(false);
    try {
      await logoutUser();
      attendanceHash.current = '#/attendance';
      window.location.hash = '#/login';
    } catch {
      setSignOutError(true);
    }
  }

  if (!runtime.ready) {
    return runtime.phase === 'error' ? (
      <main className="attendance-site-status">
        <h1>Điểm danh</h1>
        <p role="alert">Chưa thể kết nối để kiểm tra phiên đăng nhập.</p>
        <button type="button" onClick={() => bootRuntimeCore({ force: true }).catch(() => {})}>Thử lại</button>
      </main>
    ) : <p className="attendance-site-status" role="status">Đang kiểm tra phiên đăng nhập…</p>;
  }

  return (
    <div className="app-shell attendance-site" data-route={showLogin ? 'login' : 'attendance'}
      data-attendance-editorial-account={!showLogin && canAccess && admin && adminPage ? route : undefined}>
      {showLogin ? (
        <AuthPage language="vi" mode={route === 'register' ? 'register' : 'login'}
          onLogin={() => { window.location.hash = attendanceHash.current; }} />
      ) : (
        <>
          <header className="attendance-site-header">
            <a href="#/attendance" aria-label="@brianverse · Trang chính Điểm danh">
              <span className="attendance-brand-mark" aria-hidden="true">
                <img src="/brian-english-brand-logo.png" alt="" width="940" height="760" />
              </span>
              <strong className="attendance-site-title">Điểm danh</strong>
              <strong className="attendance-editorial-wordmark">@brianverse</strong>
              <span className="attendance-editorial-site-caption">Điểm danh lớp phụ đạo &amp; bồi dưỡng</span>
            </a>
            <div>
              <span className="attendance-site-account" title={user.name}>
                <span className="attendance-editorial-avatar" aria-hidden="true">{accountInitials.toLocaleUpperCase('vi-VN')}</span>
                <span className="attendance-site-account-name">{user.name}</span>
              </span>
              {admin && <a href="#/phan-quyen" aria-current={route === 'permissions' ? 'page' : undefined}>Phân quyền</a>}
              {admin && <a href="#/bao-mat" aria-current={route === 'security' ? 'page' : undefined}>Bảo mật</a>}
              <button type="button" onClick={handleLogout}>Đăng xuất</button>
            </div>
          </header>
          {signOutError && <p className="attendance-site-status" role="alert">Chưa đăng xuất được. Vui lòng thử lại.</p>}
          {canAccess && (!adminPage || admin) ? (
            <AdminMfaSecurity key={user.id} user={user} route="attendance" language="vi" requireForAttendance>
              <main className="attendance-site-content">
                {route === 'permissions' && <AttendancePermissions />}
                {route === 'security' && <AttendanceAdminSecurity required={user.attendanceMfaRequired} />}
                {route === 'attendance' && <AttendanceWorkspace key={JSON.stringify(user.permissions.allowed)} currentUser={user} language="vi" />}
              </main>
            </AdminMfaSecurity>
          ) : (
            <main className="attendance-site-status">
              <h1>Điểm danh</h1>
              <p role="alert">Tài khoản này chưa có quyền truy cập Điểm danh.</p>
            </main>
          )}
        </>
      )}
    </div>
  );
}
