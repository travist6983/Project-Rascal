import React from 'react';

export function AgeChip({ children, prefix, style }) {
  return (
    <span style={{
      padding: '4px 11px',
      borderRadius: 'var(--rascal-radius-pill)',
      background: 'var(--rascal-lav)',
      color: 'var(--rascal-peri)',
      fontFamily: 'var(--rascal-font-body)',
      fontWeight: 'var(--rascal-weight-medium)',
      fontSize: 'var(--rascal-app-size-badge)',
      letterSpacing: '0.04em',
      whiteSpace: 'nowrap',
      ...style
    }}>{prefix ? prefix + ' ' : ''}{children}</span>
  );
}
