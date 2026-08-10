import React from 'react';

const DEFAULT = ['Today', 'Timeline', 'Moments', 'Settings'];

export function TabBar({ items = DEFAULT, active = 'Today', onSelect, onAdd, style }) {
  const slots = [items[0], items[1], null, items[2], items[3]];
  return (
    <div style={{
      position: 'absolute', left: 14, right: 14, bottom: 14, height: 66,
      borderRadius: 34, background: 'var(--rascal-surface)',
      boxShadow: 'var(--rascal-shadow-tabbar)',
      display: 'flex', alignItems: 'center', justifyContent: 'space-around', padding: '0 8px',
      ...style
    }}>
      {slots.map((label, i) => (
        <span
          key={i}
          onClick={label && onSelect ? () => onSelect(label) : undefined}
          style={{
            minWidth: 52, textAlign: 'center', cursor: label && onSelect ? 'pointer' : 'default',
            fontFamily: 'var(--rascal-font-display)', fontWeight: 700, fontSize: 11,
            letterSpacing: 'var(--rascal-tracking-eyebrow)', textTransform: 'uppercase',
            color: label === active ? 'var(--rascal-terracotta)' : 'var(--rascal-muted)'
          }}
        >{label || ''}</span>
      ))}
      <div
        onClick={onAdd}
        style={{
          position: 'absolute', left: '50%', top: -14, transform: 'translateX(-50%)',
          width: 62, height: 62, borderRadius: 'var(--rascal-radius-pill)',
          background: 'var(--rascal-terracotta)', color: 'var(--rascal-canvas)',
          display: 'grid', placeItems: 'center', fontSize: 32, fontWeight: 300,
          fontFamily: 'var(--rascal-font-display)',
          boxShadow: 'var(--rascal-shadow-fab)', cursor: onAdd ? 'pointer' : 'default'
        }}
      >+</div>
    </div>
  );
}
