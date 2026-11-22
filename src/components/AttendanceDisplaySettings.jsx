import React, { useEffect, useId, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  DEFAULT_ATTENDANCE_DISPLAY,
  MAX_ATTENDANCE_WALLPAPER_OPACITY,
  loadAttendanceDisplay,
  saveAttendanceDisplay,
} from '../utils/attendanceGlobalSettings.js';

const REFRESH_INTERVAL_MS = 30_000;

export function useAttendanceDisplay(client, accountId) {
  const [result, setResult] = useState(null);
  const session = useRef(null);

  useEffect(() => {
    if (!client || !accountId) return undefined;
    let reading = false;
    const scope = { accountId, revision: 0, saving: false, refresh };
    session.current = scope;

    async function refresh() {
      if (reading || scope.saving || document.hidden) return;
      reading = true;
      const revision = scope.revision;
      const current = () => session.current === scope && revision === scope.revision;
      try {
        const display = await loadAttendanceDisplay(client);
        if (current()) setResult({ accountId, display, failed: false });
      } catch {
        if (current()) setResult((previous) => ({
          accountId,
          display: previous?.accountId === accountId ? previous.display : null,
          failed: true,
        }));
      } finally {
        reading = false;
      }
    }

    void refresh();
    const timer = window.setInterval(refresh, REFRESH_INTERVAL_MS);
    window.addEventListener('focus', refresh);
    document.addEventListener('visibilitychange', refresh);
    return () => {
      session.current = null;
      window.clearInterval(timer);
      window.removeEventListener('focus', refresh);
      document.removeEventListener('visibilitychange', refresh);
    };
  }, [client, accountId]);

  const stored = accountId && result?.accountId === accountId ? result : null;
  return {
    display: stored?.display ?? DEFAULT_ATTENDANCE_DISPLAY,
    ready: Boolean(stored?.display),
    failed: Boolean(stored?.failed),
    refresh: () => session.current?.refresh(),
    async save(display) {
      const scope = session.current;
      if (!scope || scope.accountId !== accountId || scope.saving) throw new Error('Display settings are unavailable.');
      scope.saving = true;
      scope.revision += 1;
      try {
        const saved = await saveAttendanceDisplay(client, display);
        if (session.current === scope) setResult({ accountId, display: saved, failed: false });
      } finally {
        scope.saving = false;
      }
    },
  };
}

export default function AttendanceDisplaySettings({ settings, draft, onPreview }) {
  const dialog = useRef(null);
  const titleId = useId();
  const descriptionId = useId();
  const [status, setStatus] = useState('idle');
  const display = draft ?? settings.display;
  const saving = status === 'saving';
  const disabled = saving || !settings.ready;
  const changed = display.opacity !== settings.display.opacity || display.clearSurfaces !== settings.display.clearSurfaces;

  function preview(value) {
    onPreview(value);
    setStatus('idle');
  }

  async function save(event) {
    event.preventDefault();
    if (disabled || !changed) return;
    setStatus('saving');
    try {
      await settings.save(display);
      onPreview(null);
      setStatus('saved');
    } catch {
      setStatus('error');
    }
  }

  return <>
    <button type="button" aria-haspopup="dialog" onClick={() => {
      void settings.refresh();
      dialog.current?.showModal();
    }}>Hiển thị</button>
    {createPortal(
      <dialog ref={dialog} className="attendance-display-dialog" aria-labelledby={titleId} aria-describedby={descriptionId}
        onClose={() => preview(null)} onCancel={(event) => { if (saving) event.preventDefault(); }}>
        <form method="dialog" className="attendance-display-dialog__header">
          <h2 id={titleId}>Cài đặt hiển thị</h2>
          <button type="submit" disabled={saving} autoFocus>Đóng</button>
        </form>
        <p id={descriptionId}>Chỉnh để xem trước, rồi lưu để áp dụng cho mọi tài khoản giáo viên.</p>
        <form onSubmit={save} aria-busy={saving}>
          <label className="attendance-display-dialog__slider">
            <span>Độ đậm nền Ngọ Môn <b aria-hidden="true">{display.opacity}%</b></span>
            <input type="range" min="0" max={MAX_ATTENDANCE_WALLPAPER_OPACITY} value={display.opacity}
              disabled={disabled} aria-label="Độ đậm nền Ngọ Môn" aria-valuetext={`${display.opacity}%`}
              onChange={(event) => preview({ ...display, opacity: event.target.valueAsNumber })} />
          </label>
          <label className="attendance-display-dialog__check">
            <input type="checkbox" checked={display.clearSurfaces} disabled={disabled}
              onChange={(event) => preview({ ...display, clearSurfaces: event.target.checked })} />
            Tăng tương phản bảng và ô nhập
          </label>
          {!settings.ready && (settings.failed ? (
            <p role="alert">Chưa tải được cài đặt chung. <button type="button" onClick={settings.refresh}>Thử lại</button></p>
          ) : <p role="status">Đang tải cài đặt chung…</p>)}
          {status === 'error' && <p role="alert">Chưa lưu được cài đặt chung. Vui lòng thử lại.</p>}
          {status === 'saved' && <p role="status">Đã lưu cài đặt cho toàn bộ tài khoản giáo viên.</p>}
          <div className="attendance-display-dialog__actions">
            <button type="button" disabled={disabled} onClick={() => preview(DEFAULT_ATTENDANCE_DISPLAY)}>Về mặc định</button>
            <button type="submit" disabled={disabled || !changed}>{saving ? 'Đang lưu…' : 'Lưu cài đặt chung'}</button>
          </div>
        </form>
      </dialog>,
      document.body,
    )}
  </>;
}
