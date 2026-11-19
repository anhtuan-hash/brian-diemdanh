import React, { useEffect, useId, useRef, useState } from 'react';
import {
  getSupplementalAttendanceEditSnapshot,
  updateSupplementalAttendanceSession,
} from '../../attendance/supplementalLearningApi.js';
import {
  ABSENCE_REASON_OPTIONS,
  ATTENDANCE_STATUS,
  attendanceStatusLabel,
} from '../../utils/extraClassAttendance.js';
import './AttendanceAdjustment.css';

const auditTime = new Intl.DateTimeFormat('vi-VN', {
  timeZone: 'Asia/Ho_Chi_Minh', dateStyle: 'short', timeStyle: 'short',
});
const lockedReasons = {
  edit_window_expired: 'Đã hết 30 phút điều chỉnh kể từ lúc chốt điểm danh.',
  not_session_teacher: 'Chỉ người đã chốt buổi này được điều chỉnh trong thời gian cho phép.',
  invalid_checked_at: 'Không xác định được thời điểm chốt buổi.',
  missing_permission: 'Tài khoản chưa có quyền điều chỉnh điểm danh.',
};
const REASONS = [...ABSENCE_REASON_OPTIONS, { value: 'unspecified', label: 'Chưa xác định' }];

function editableRecord(record) {
  const absent = record.status === ATTENDANCE_STATUS.ABSENT;
  return {
    ...record,
    absence_reason_code: absent
      ? REASONS.find((reason) => reason.value === record.absence_reason_code)?.value || 'unspecified'
      : '',
    absence_note: absent ? String(record.absence_note ?? '') : '',
  };
}

function accessDuration(access) {
  return Date.parse(access?.expires_at) - Date.parse(access?.server_now);
}

function isAllowed(access) {
  return access?.allowed === true && (access.bypass || accessDuration(access) > 0);
}

async function rpc(client, name, params) {
  const { data, error } = await client.rpc(name, params);
  if (error) throw error;
  return data;
}

async function getExtraAccess(client, sessionId) {
  return rpc(client, 'bes_get_extra_attendance_edit_access', { p_session_id: sessionId });
}

export default function AttendanceAdjustment({
  client, session, recordColumns, disabled, onSaved,
}) {
  const supplemental = Boolean(session.supplemental_session_id);
  const sessionId = session.supplemental_session_id || session.id;
  const [access, setAccess] = useState(null);
  const [accessFailed, setAccessFailed] = useState(false);
  const [deadline, setDeadline] = useState(0);
  const [now, setNow] = useState(Date.now);
  const [latestChange, setLatestChange] = useState(null);
  const [auditRevision, setAuditRevision] = useState(0);
  const [phase, setPhase] = useState('idle');
  const [draft, setDraft] = useState([]);
  const [note, setNote] = useState('');
  const [error, setError] = useState('');
  const trigger = useRef(null);
  const dialog = useRef(null);
  const operation = useRef(0);
  const headingId = useId();
  const remaining = Math.max(0, Math.ceil((deadline - now) / 1000));
  const expired = access?.reason === 'edit_window_expired'
    || (isAllowed(access) && !access.bypass && !remaining);
  const allowed = isAllowed(access) && !expired;

  function updateAccess(next) {
    const observedAt = Date.now();
    setAccess(next);
    setDeadline(isAllowed(next) && !next.bypass ? observedAt + accessDuration(next) : 0);
    setNow(observedAt);
  }

  useEffect(() => {
    const controller = { active: true };
    const permissionRequest = supplemental
      ? getSupplementalAttendanceEditSnapshot(client, sessionId).then((snapshot) => {
        if (controller.active) setLatestChange(snapshot?.latestChange);
        return snapshot?.access;
      })
      : getExtraAccess(client, sessionId);

    if (!supplemental) {
      void Promise.resolve(client.from('bes_extra_attendance_record_changes')
        .select('changed_at,changed_by_name').eq('session_id', sessionId)
        .order('changed_at', { ascending: false }).limit(1).maybeSingle()).then(({ data, error }) => {
          if (controller.active && !error) setLatestChange(data);
        }).catch(() => {});
    }

    permissionRequest.then((result) => {
      if (controller.active) {
        updateAccess(result);
        setAccessFailed(false);
      }
    }, () => {
      if (controller.active) setAccessFailed(true);
    });
    return () => {
      controller.active = false;
    };
  }, [client, sessionId, supplemental, auditRevision]);

  const countingDown = remaining > 0;
  useEffect(() => {
    if (!deadline || !countingDown) return undefined;
    const tick = window.setInterval(() => setNow(Date.now()), 1000);
    const expire = window.setTimeout(() => setNow(Date.now()), Math.max(0, deadline - Date.now()));
    return () => {
      window.clearInterval(tick);
      window.clearTimeout(expire);
    };
  }, [deadline, countingDown]);

  useEffect(() => () => { operation.current += 1; }, []);

  async function openEditor() {
    const request = ++operation.current;
    setPhase('loading');
    setError('');
    dialog.current.showModal();
    try {
      let snapshot;
      if (supplemental) {
        snapshot = await getSupplementalAttendanceEditSnapshot(client, sessionId);
      } else {
        const [permission, sessionResult, recordResult] = await Promise.all([
          getExtraAccess(client, sessionId),
          client.from('bes_extra_attendance_sessions').select('note').eq('id', sessionId).single(),
          client.from('bes_extra_attendance_records').select(recordColumns).eq('session_id', sessionId)
            .order('student_full_name', { ascending: true }).order('id', { ascending: true }),
        ]);
        if (sessionResult.error || recordResult.error) throw sessionResult.error || recordResult.error;
        snapshot = { access: permission, session: sessionResult.data, records: recordResult.data };
      }

      if (request !== operation.current) return;
      updateAccess(snapshot?.access);
      setAccessFailed(false);
      if (!isAllowed(snapshot?.access)) {
        setPhase('unavailable');
        setError(lockedReasons[snapshot?.access?.reason] || 'Tài khoản hiện không có quyền điều chỉnh buổi này.');
        return;
      }
      setDraft((snapshot.records || []).map(editableRecord));
      setNote(snapshot.session?.note || '');
      setPhase('ready');
    } catch (loadError) {
      if (request !== operation.current) return;
      setPhase('unavailable');
      setError(loadError?.message || 'Chưa tải được dữ liệu điều chỉnh.');
    }
  }

  function closeEditor() {
    operation.current += 1;
    setPhase('idle');
    trigger.current?.focus();
  }

  function updateRecord(id, changes) {
    setDraft((current) => current.map((record) => (
      record.id === id ? editableRecord({ ...record, ...changes }) : record
    )));
  }

  async function saveAdjustment(event) {
    event.preventDefault();
    if (phase !== 'ready' || !allowed) return;
    const request = ++operation.current;
    setPhase('saving');
    setError('');
    const updatedRecords = draft.map((record) => ({ ...record, absence_note: record.absence_note.trim() }));
    const updatedNote = note.trim();
    try {
      let updatedSession;
      if (supplemental) {
        const result = await updateSupplementalAttendanceSession(client, {
          sessionId, records: updatedRecords, note: updatedNote,
        });
        const saved = result.session;
        updatedSession = {
          ...session,
          total_students: saved.total_students,
          present_count: Number(saved.present_count) + Number(saved.tardy_count),
          tardy_count: saved.tardy_count,
          absent_count: saved.absent_count,
          note: saved.session_note,
          history_records: updatedRecords,
        };
      } else {
        const saved = await rpc(client, 'bes_update_extra_attendance_session', {
          p_session_id: sessionId,
          p_records: updatedRecords.map((record) => ({
            record_id: record.id,
            status: record.status,
            reason_code: record.absence_reason_code,
            note: record.absence_note,
          })),
          p_note: updatedNote,
        });
        updatedSession = Array.isArray(saved) ? saved[0] : saved;
      }
      if (!updatedSession?.id) throw new Error('Chưa nhận được xác nhận lưu điều chỉnh.');
      if (request !== operation.current) return;
      onSaved(updatedSession, updatedRecords);
      setAuditRevision((revision) => revision + 1);
      dialog.current?.close();
    } catch (saveError) {
      if (request !== operation.current) return;
      setError(saveError?.message || 'Chưa lưu được điều chỉnh điểm danh.');
    } finally {
      if (request === operation.current) setPhase('ready');
    }
  }

  const saving = phase === 'saving';
  const formReady = phase === 'ready' || saving;
  const expiredMessage = lockedReasons.edit_window_expired;
  const countdown = allowed && !access.bypass
    ? `Còn ${Math.floor(remaining / 60)} phút ${String(remaining % 60).padStart(2, '0')} giây để điều chỉnh.`
    : '';
  const locked = expired ? expiredMessage : access && !allowed
    ? lockedReasons[access.reason] || 'Tài khoản hiện không có quyền điều chỉnh buổi này.'
    : '';
  const changeTime = Date.parse(latestChange?.changed_at);

  return <>
    <div className="attendance-adjustment-status">
      {(countdown || locked) && <small>{countdown || locked}</small>}
      {Number.isFinite(changeTime) && (
        <small><strong>Điều chỉnh gần nhất</strong> · {latestChange.changed_by_name || 'Không ghi nhận người sửa'}
          {' · '}{auditTime.format(changeTime)}</small>
      )}
    </div>
    {(allowed || accessFailed) && (
      <button ref={trigger} type="button" className="attendance-adjustment-trigger"
        disabled={disabled} onClick={openEditor}>Điều chỉnh điểm danh</button>
    )}
    <dialog ref={dialog} className="attendance-adjustment-dialog" aria-labelledby={headingId}
      onClose={closeEditor} onCancel={(event) => { if (saving) event.preventDefault(); }}>
      <form onSubmit={saveAdjustment}>
        <header>
          <h3 id={headingId}>Điều chỉnh điểm danh</h3>
          <p>{session.class_name}</p>
        </header>
        {phase === 'loading' && <p role="status">Đang tải danh sách điểm danh…</p>}
        {formReady && countdown && <p>{countdown}</p>}
        {formReady && (
          <fieldset disabled={saving || !allowed}>
            <legend>Trạng thái học sinh</legend>
            <div className="attendance-adjustment-students">
              {draft.map((record) => (
                <div className="attendance-adjustment-student" key={record.id}>
                  <label>
                      <b>{record.student_full_name}</b>
                      {record.school_class_name && <small>{record.school_class_name}</small>}
                      <select aria-label={'Trạng thái của ' + record.student_full_name}
                        value={record.status} onChange={(event) => updateRecord(record.id, { status: event.target.value })}>
                        {Object.values(ATTENDANCE_STATUS).map((status) => (
                          <option key={status} value={status}>{attendanceStatusLabel(status)}</option>
                        ))}
                      </select>
                  </label>
                  {record.status === ATTENDANCE_STATUS.ABSENT && (
                    <div className="attendance-adjustment-reason">
                      <label>Lý do vắng
                        <select value={record.absence_reason_code}
                          onChange={(event) => updateRecord(record.id, { absence_reason_code: event.target.value })}>
                          {REASONS.map((reason) => <option key={reason.value} value={reason.value}>{reason.label}</option>)}
                        </select>
                      </label>
                      <label>Ghi chú vắng
                        <input value={record.absence_note} required={record.absence_reason_code === 'other'}
                          onChange={(event) => updateRecord(record.id, { absence_note: event.target.value })} />
                      </label>
                    </div>
                  )}
                </div>
              ))}
              {!draft.length && <p>Buổi học chưa có bản ghi điểm danh của học sinh.</p>}
            </div>
            <label>Ghi chú buổi học
              <textarea rows={2} value={note} onChange={(event) => setNote(event.target.value)} />
            </label>
          </fieldset>
        )}
        {(error || expired) && <p className="attendance-adjustment-error" role="alert">{error || expiredMessage}</p>}
        <footer>
          <button type="button" disabled={saving} onClick={() => dialog.current.close()}>
            {phase === 'unavailable' || expired ? 'Đóng' : 'Hủy'}
          </button>
          {formReady && (
            <button type="submit" disabled={saving || !allowed}>{saving ? 'Đang lưu…' : 'Lưu điều chỉnh'}</button>
          )}
        </footer>
      </form>
    </dialog>
  </>;
}
