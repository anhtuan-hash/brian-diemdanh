import React from 'react';

export default function AttendanceEditorialHeading({ title, metrics = [], className = '' }) {
  return (
    <header className={`ae-heading ${className}`}>
      <h1>{title}</h1>
      {metrics.length > 0 && (
        <dl className="ae-heading__metrics">
          {metrics.map(({ label, value }) => (
            <div key={label} className="ae-heading__metric">
              <dt>{label}</dt>
              <dd>{value ?? '—'}</dd>
            </div>
          ))}
        </dl>
      )}
    </header>
  );
}
