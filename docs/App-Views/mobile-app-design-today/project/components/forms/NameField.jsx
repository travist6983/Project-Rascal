import React from 'react';

export function NameField({ value, placeholder = '', caret = true, size = 38, style }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 2, borderBottom: '2px solid var(--rascal-terracotta)', paddingBottom: 12, ...style }}>
      <span style={{
        fontFamily: 'var(--rascal-font-display)', fontWeight: 800, fontSize: size,
        letterSpacing: 'var(--rascal-tracking-display)',
        color: value ? 'var(--rascal-ink)' : 'var(--rascal-muted-soft)',
        minHeight: size + 10, lineHeight: (size + 10) + 'px'
      }}>{value || placeholder}</span>
      {caret ? <span style={{
        width: 3, height: size, background: 'var(--rascal-terracotta)', display: 'inline-block',
        animation: 'rascal-caret-blink 1s step-end infinite'
      }} /> : null}
    </div>
  );
}
