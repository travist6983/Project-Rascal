import React from 'react';

const TINT = { none: null, peach: 'var(--rascal-peach-deep)', lavender: 'var(--rascal-lav)', sage: 'var(--rascal-sage)' };

export function Card({ tint = 'none', selected, lifted, radius = 'var(--rascal-radius-card)', padding = 18, children, onClick, style, ...rest }) {
  const fill = TINT[tint];
  return (
    <div
      onClick={onClick}
      style={{
        padding,
        borderRadius: radius,
        background: selected ? 'var(--rascal-peach-deep)' : (fill || 'var(--rascal-surface)'),
        border: selected
          ? 'var(--rascal-border-selected-width) solid var(--rascal-terracotta)'
          : (fill ? 'none' : 'var(--rascal-border-hairline-width) solid var(--rascal-border)'),
        boxShadow: fill && !selected ? 'none' : (lifted ? 'var(--rascal-shadow-lift)' : 'var(--rascal-shadow)'),
        cursor: onClick ? 'pointer' : 'default',
        transition: 'box-shadow var(--rascal-dur-hover) var(--rascal-ease-enter)',
        ...style
      }}
      {...rest}
    >{children}</div>
  );
}
