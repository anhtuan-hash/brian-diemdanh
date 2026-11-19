import React, { useCallback, useEffect, useState } from 'react';

const vietnamClock = new Intl.DateTimeFormat('en-GB', {
  timeZone: 'Asia/Ho_Chi_Minh', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
});

function validSettings(settings) {
  return [settings?.teacher_start_time, settings?.teacher_end_time].every((time) => /^\d{2}:\d{2}$/.test(time || ''))
    && typeof settings?.enforce_teacher_time_window === 'boolean'
    && Number.isFinite(Date.parse(settings.server_now));
}

export function useAttendanceTimeSettings(client, enabled) {
  const [settings, setSettings] = useState(null);
  const [unavailable, setUnavailable] = useState(false);
  const [now, setNow] = useState(Date.now);
  const acceptSettings = useCallback((data) => {
    if (!validSettings(data)) throw new Error('Chưa đọc được cài đặt khung giờ.');
    const observedAt = Date.now();
    setSettings({ ...data, clockOffset: Date.parse(data.server_now) - observedAt });
    setNow(observedAt);
    setUnavailable(false);
  }, []);

  useEffect(() => {
    if (!client || !enabled) return undefined;
    let active = true;
    let request = 0;
    async function refresh() {
      const id = ++request;
      try {
        const { data, error } = await client.rpc('bes_get_attendance_access_settings');
        if (!active || id !== request) return;
        if (error) throw error;
        acceptSettings(data);
      } catch {
        if (active && id === request) setUnavailable(true);
      }
    }
    function onFocus() {
      setNow(Date.now());
      void refresh();
    }
    void refresh();
    const poll = window.setInterval(refresh, 45000);
    window.addEventListener('focus', onFocus);
    return () => {
      active = false;
      window.clearInterval(poll);
      window.removeEventListener('focus', onFocus);
    };
  }, [client, enabled, acceptSettings]);

  const shouldWatchClock = enabled && settings?.enforce_teacher_time_window && !settings.bypass_time_window;
  useEffect(() => {
    if (!shouldWatchClock) return undefined;
    const tick = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(tick);
  }, [shouldWatchClock]);

  const currentTime = settings ? vietnamClock.format(now + settings.clockOffset) : '';
  const start = settings ? settings.teacher_start_time + ':00' : '';
  const end = settings ? settings.teacher_end_time + ':00' : '';
  const inWindow = start < end ? start <= currentTime && currentTime <= end
    : start !== end && (start <= currentTime || currentTime <= end);
  const blocked = Boolean(settings?.enforce_teacher_time_window && !settings.bypass_time_window && !inWindow && !unavailable);
  return { settings, unavailable, blocked, acceptSettings };
}

export default function AttendanceTimeSettings({ client, settings, unavailable, onSaved }) {
  const [draft, setDraft] = useState(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [saved, setSaved] = useState(false);
  const form = draft || (settings && {
    enabled: settings.enforce_teacher_time_window,
    start: settings.teacher_start_time,
    end: settings.teacher_end_time,
  });
  function update(change) {
    setDraft({ ...form, ...change });
    setSaved(false);
    setError('');
  }

  async function submit(event) {
    event.preventDefault();
    if (!form || saving) return;
    if (!form.start || !form.end || form.start === form.end) {
      setError('Giờ bắt đầu và giờ kết thúc phải khác nhau.');
      return;
    }
    setSaving(true);
    setSaved(false);
    setError('');
    try {
      const { data, error: saveError } = await client.rpc('bes_admin_set_attendance_time_restriction', {
        p_enabled: form.enabled, p_start: form.start, p_end: form.end,
      });
      if (saveError) throw saveError;
      onSaved(data);
      setDraft(null);
      setSaved(true);
    } catch (saveError) {
      setError(saveError?.message || 'Chưa lưu được khung giờ điểm danh.');
    } finally {
      setSaving(false);
    }
  }

  return <details className="attendance-time-settings">
    <summary>Cài đặt khung giờ điểm danh</summary>
    {!form || unavailable ? <p role="status">{unavailable
      ? 'Chưa đọc được cài đặt khung giờ. Hãy tải lại hoặc thử lại sau.'
      : 'Đang đọc cài đặt khung giờ…'}</p> : (
      <form onSubmit={submit}>
        <fieldset className="ae-field-row" disabled={saving || !settings.can_administer}>
          <label className="attendance-time-settings__toggle">
            <input type="checkbox" checked={form.enabled} onChange={(event) => update({ enabled: event.target.checked })} />
            Bật giới hạn thời gian
          </label>
          <label>Giờ bắt đầu<input type="time" value={form.start} onChange={(event) => update({ start: event.target.value })} required /></label>
          <label>Giờ kết thúc<input type="time" value={form.end} onChange={(event) => update({ end: event.target.value })} required /></label>
          <button type="submit" className="ae-button ae-button--primary">{saving ? 'Đang lưu…' : 'Lưu cài đặt'}</button>
        </fieldset>
        <p>Giờ Việt Nam. Ngoài khung giờ, tài khoản thuộc diện giới hạn chỉ được xem phiếu.</p>
        {saved && <p role="status">Đã lưu khung giờ điểm danh.</p>}
        {error && <p role="alert">{error}</p>}
      </form>
    )}
  </details>;
}
