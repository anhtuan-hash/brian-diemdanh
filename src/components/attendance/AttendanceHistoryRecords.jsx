import React, { useId } from 'react';
import { ABSENCE_REASON_OPTIONS } from '../../utils/extraClassAttendance.js';

export default function AttendanceHistoryRecords({ records, absent = false, phase }) {
  const headingId = useId();
  const label = absent ? 'Học sinh vắng' : 'Học sinh đi trễ';

  return (
    <section className="attendance-history-records" aria-labelledby={headingId}
      aria-busy={phase === 'loading'}>
      <header>
        <h3 id={headingId}>{label}</h3>
        {phase === 'ready' && <span>{records.length} học sinh</span>}
      </header>
      {phase !== 'ready' ? (
        <p className="attendance-history-records__message" role="status">
          {phase === 'error' ? 'Chưa tải được danh sách học sinh.' : 'Đang tải danh sách học sinh…'}
        </p>
      ) : records.length === 0 ? (
        <p className="attendance-history-records__message">
          {absent ? 'Không có học sinh vắng.' : 'Không có học sinh đi trễ.'}
        </p>
      ) : (
        <div className="attendance-history-records__scroll" role="region" aria-label={label} tabIndex={0}>
          <table aria-labelledby={headingId} data-absent={absent}>
            <thead>
              <tr>
                <th scope="col">STT</th>
                <th scope="col">Học sinh</th>
                <th scope="col">Lớp</th>
                {absent && <th scope="col">Lý do</th>}
              </tr>
            </thead>
            <tbody>
              {records.map((record, index) => (
                <tr key={record.id}>
                  <td>{index + 1}</td>
                  <th scope="row">
                    {record.student_full_name || 'Chưa ghi tên'}
                    {record.student_code && <small>{record.student_code}</small>}
                  </th>
                  <td>{record.school_class_name || '—'}</td>
                  {absent && <td>
                    {ABSENCE_REASON_OPTIONS.find(({ value }) => value === record.absence_reason_code)?.label || 'Chưa ghi lý do'}
                    {record.absence_note && <small>{record.absence_note}</small>}
                  </td>}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
