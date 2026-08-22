import React from 'react';

export function Sheet({ open = true, onScrimClick, children, style }) {
  if (!open) return null;
  return (
    <div
      onClick={onScrimClick}
      style={{ position: 'absolute', inset: 0, background: 'var(--rascal-scrim)', display: 'flex', alignItems: 'flex-end', zIndex: 70 }}
    >
      <div
        onClick={e => e.stopPropagation()}
        style={{
          width: '100%',
          background: 'var(--rascal-surface)',
          borderRadius: 'var(--rascal-radius-sheet) var(--rascal-radius-sheet) 0 0',
          borderTop: '1px solid var(--rascal-border)',
          boxShadow: 'var(--rascal-shadow-sheet)',
          padding: '26px 26px var(--rascal-app-safe-bottom)',
          paddingBottom: 34,
          animation: 'rascal-sheet-up var(--rascal-dur-enter) var(--rascal-ease-enter)',
          ...style
        }}
      >{children}</div>
    </div>
  );
}
