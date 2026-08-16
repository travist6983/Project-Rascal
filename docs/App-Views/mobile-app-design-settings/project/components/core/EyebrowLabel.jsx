import React from 'react';

export function EyebrowLabel({ children, tone = 'muted', style }) {
  return (
    <p style={{
      margin: 0,
      fontFamily: 'var(--rascal-font-body)',
      fontWeight: 'var(--rascal-weight-medium)',
      fontSize: 'var(--rascal-size-eyebrow)',
      textTransform: 'uppercase',
      letterSpacing: 'var(--rascal-tracking-eyebrow)',
      color: tone === 'accent' ? 'var(--rascal-terracotta)' : 'var(--rascal-muted)',
      ...style
    }}>{children}</p>
  );
}
