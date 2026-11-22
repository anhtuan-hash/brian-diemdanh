import React from 'react';
import GlobalAttendanceReadOnlyNavigationTab from '../components/GlobalAttendanceReadOnlyNavigationTab.jsx';
import './AttendanceWorkspace.css';
import './AttendanceWorkspaceRebuilt.css';
import './AttendanceWorkspaceHero.css';
import './AttendanceQuickLayoutFix.css';
import './AttendanceMobileAudit.css';
import './AttendanceHistoryIphoneViewportFix.css';
import './AttendanceQuickEditorial.css';
import './AttendanceEditorial.css';
import './AttendanceEditorialWorkspaces.css';
import './AttendanceWallpaper.css';

/**
 * A first-class attendance workspace at #/attendance.
 *
 * Reuses the existing authentication, RLS, attendance queries, permissions,
 * and action handlers. The legacy overlay stays available for older event
 * integrations, but normal access is now an inline page, not a modal.
 */
export default function AttendanceWorkspace({currentUser, language='vi'}) {
  return <div className="attendance-workspace-page">
    <GlobalAttendanceReadOnlyNavigationTab currentUser={currentUser} language={language} standalone />
    <footer className="attendance-wallpaper-credit">
      Minh họa Ngọ Môn Huế, phác lại từ ảnh <a href="https://commons.wikimedia.org/wiki/File:Ngo_Mon.jpg" target="_blank" rel="noreferrer">Lưu Ly</a>
      {' · '}<a href="https://creativecommons.org/licenses/by-sa/3.0/" target="_blank" rel="noreferrer">CC BY-SA 3.0</a>
    </footer>
  </div>;
}
