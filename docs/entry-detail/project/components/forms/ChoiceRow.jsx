import React from 'react';

export function ChoiceRow({ selected, children, onClick, style }) {
  return (
    <button
      onClick={onClick}
      style={{
        width: '100%', textAlign: 'left', padding: '18px 20px',
        borderRadius: 'var(--rascal-radius-card)', cursor: 'pointer',
        fontFamily: 'var(--rascal-font-display)', fontWeight: 700, fontSize: 17, lineHeight: 1.3,
        color: 'var(--rascal-ink)',
        background: selected ? 'var(--rascal-peach-deep)' : 'var(--rascal-surface)',
        border: (selected ? 'var(--rascal-border-selected-width) solid var(--rascal-terracotta)' : 'var(--rascal-border-selected-width) solid var(--rascal-border)'),
        boxShadow: selected ? '0 2px 8px var(--rascal-terracotta-a10)' : 'none',
        transition: 'transform var(--rascal-dur-hover) var(--rascal-ease-enter)',
        ...style
      }}
    >{children}</button>
  );
}
