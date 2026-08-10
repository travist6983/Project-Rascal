import React from 'react';

export function RecordButton({ recording, onClick, style }) {
  return (
    <button
      onClick={onClick}
      aria-label={recording ? 'Stop recording' : 'Start recording'}
      style={{
        width: 92, height: 92, padding: 0,
        borderRadius: 'var(--rascal-radius-pill)',
        border: '5px solid ' + (recording ? 'var(--rascal-terracotta)' : 'var(--rascal-border)'),
        background: 'var(--rascal-surface)',
        display: 'grid', placeItems: 'center', cursor: 'pointer',
        animation: recording ? 'rascal-pulse 1.6s ease-out infinite' : undefined,
        ...style
      }}
    >
      <span style={{
        display: 'block',
        background: 'var(--rascal-terracotta)',
        width: recording ? 28 : 64,
        height: recording ? 28 : 64,
        borderRadius: recording ? 6 : 'var(--rascal-radius-pill)',
        transition: 'all var(--rascal-dur-enter) var(--rascal-ease-enter)'
      }} />
    </button>
  );
}
