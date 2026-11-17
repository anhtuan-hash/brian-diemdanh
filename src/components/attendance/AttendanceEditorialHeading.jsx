import React from 'react';

export default function AttendanceEditorialHeading({ title, metrics = [], className = '', loading = false }) {
  const headingClass = className ? `ae-heading ${className}` : 'attendance-editorial-heading';
  const metricsClass = className ? 'ae-heading__metrics' : 'attendance-editorial-heading__metrics';

  return (
    <header className={headingClass}>
      <h1>{title}</h1>
      {metrics.length > 0 && (
        <dl className={metricsClass} aria-live="polite" aria-busy={loading}>
          {metrics.map(({ label, value }, index) => (
            <div key={label} className={className ? 'ae-heading__metric' : (index === 0 ? 'is-primary' : undefined)}>
              <dt>{label}</dt>
              <dd>{loading ? '—' : (value ?? '—')}</dd>
            </div>
          ))}
        </dl>
      )}
    </header>
  );
}
