import React from 'react';

export function ProgressBar({ step = 1, total = 5, style }) {
  const pct = Math.max(0, Math.min(1, step / total)) * 100;
  return (
    <div style={{ height: 4, borderRadius: 'var(--rascal-radius-pill)', background: 'var(--rascal-border)', ...style }}>
      <div style={{
        height: '100%', width: pct + '%',
        borderRadius: 'var(--rascal-radius-pill)',
        background: 'var(--rascal-terracotta)',
        transition: 'width var(--rascal-dur-settle) var(--rascal-ease-enter)'
      }} />
    </div>
  );
}
