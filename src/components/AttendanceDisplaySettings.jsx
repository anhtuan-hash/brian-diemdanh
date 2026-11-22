import React, { useId, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';

const DEFAULT_DISPLAY = { opacity: 15, clearSurfaces: true };
const MAX_OPACITY = 40;

function storageKey(accountId) {
  return `attendance-display:${accountId}`;
}

function readDisplay(accountId) {
  try {
    const saved = JSON.parse(window.localStorage.getItem(storageKey(accountId)));
    return {
      opacity: Number.isInteger(saved?.opacity) && saved.opacity >= 0 && saved.opacity <= MAX_OPACITY
        ? saved.opacity : DEFAULT_DISPLAY.opacity,
      clearSurfaces: typeof saved?.clearSurfaces === 'boolean'
        ? saved.clearSurfaces : DEFAULT_DISPLAY.clearSurfaces,
    };
  } catch {
    return DEFAULT_DISPLAY;
  }
}

export function useAttendanceDisplay(accountId) {
  const [draft, setDraft] = useState(null);
  const saved = useMemo(() => accountId ? readDisplay(accountId) : DEFAULT_DISPLAY, [accountId]);
  const display = draft?.accountId === accountId ? draft.value : saved;

  function updateDisplay(value) {
    if (!accountId) return;
    setDraft({ accountId, value });
    try {
      window.localStorage.setItem(storageKey(accountId), JSON.stringify(value));
    } catch {
      // Keep the active preference when the browser blocks local storage.
    }
  }

  return [display, updateDisplay];
}

export default function AttendanceDisplaySettings({ display, onChange }) {
  const dialog = useRef(null);
  const titleId = useId();
  const descriptionId = useId();

  return <>
    <button type="button" aria-haspopup="dialog" onClick={() => dialog.current?.showModal()}>Hiển thị</button>
    {createPortal(
      <dialog ref={dialog} className="attendance-display-dialog" aria-labelledby={titleId} aria-describedby={descriptionId}>
        <form method="dialog" className="attendance-display-dialog__header">
          <h2 id={titleId}>Cài đặt hiển thị</h2>
          <button type="submit" autoFocus>Đóng</button>
        </form>
        <p id={descriptionId}>Áp dụng ngay và lưu cho tài khoản này trên trình duyệt hiện tại.</p>
        <label className="attendance-display-dialog__slider">
          <span>Độ đậm nền Ngọ Môn <b aria-hidden="true">{display.opacity}%</b></span>
          <input type="range" min="0" max={MAX_OPACITY} value={display.opacity}
            aria-label="Độ đậm nền Ngọ Môn" aria-valuetext={`${display.opacity}%`}
            onChange={(event) => onChange({ ...display, opacity: event.target.valueAsNumber })} />
        </label>
        <label className="attendance-display-dialog__check">
          <input type="checkbox" checked={display.clearSurfaces}
            onChange={(event) => onChange({ ...display, clearSurfaces: event.target.checked })} />
          Tăng tương phản bảng và ô nhập
        </label>
        <button type="button" onClick={() => onChange(DEFAULT_DISPLAY)}>Về mặc định</button>
      </dialog>,
      document.body,
    )}
  </>;
}
