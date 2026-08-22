import React from 'react';

export function Wordmark({ size = 19, inverted, style }) {
  return (
    <span style={{
      fontFamily: 'var(--rascal-font-display)',
      fontWeight: 'var(--rascal-weight-display)',
      fontSize: size,
      letterSpacing: 'var(--rascal-tracking-wordmark)',
      color: inverted ? 'var(--rascal-canvas)' : 'var(--rascal-ink)',
      ...style
    }}>RASCAL</span>
  );
}
