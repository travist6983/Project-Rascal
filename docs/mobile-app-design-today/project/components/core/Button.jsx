import React from 'react';

const TONE = {
  primary:   { bg: 'var(--rascal-terracotta)', fg: 'var(--rascal-canvas)', border: 'none' },
  written:   { bg: '#4A56D6',                  fg: 'var(--rascal-canvas)', border: 'none' },
  secondary: { bg: 'transparent',              fg: 'var(--rascal-muted)',  border: '1.5px solid var(--rascal-border)' },
  dark:      { bg: 'var(--rascal-ink)',        fg: 'var(--rascal-canvas)', border: 'none' },
  quiet:     { bg: 'transparent',              fg: 'var(--rascal-muted)',  border: 'none' }
};
const SIZE = { lg: { pad: '19px 26px', font: 18 }, md: { pad: '17px 24px', font: 17 }, sm: { pad: '13px 20px', font: 15 } };

export function Button({ tone = 'primary', size = 'lg', block = true, disabled, radius, children, onClick, style, ...rest }) {
  const t = TONE[tone] || TONE.primary;
  const s = SIZE[size] || SIZE.lg;
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      style={{
        width: block ? '100%' : 'auto',
        padding: s.pad,
        border: t.border,
        borderRadius: radius || 'var(--rascal-radius-pill)',
        background: disabled ? 'var(--rascal-ink-disabled)' : t.bg,
        color: disabled ? 'var(--rascal-canvas)' : t.fg,
        fontFamily: 'var(--rascal-font-display)',
        fontWeight: 700,
        fontSize: s.font,
        lineHeight: 1.1,
        minHeight: 44,
        cursor: disabled ? 'default' : 'pointer',
        textDecoration: tone === 'quiet' ? 'underline' : 'none',
        transition: 'transform var(--rascal-dur-press) var(--rascal-ease-enter)',
        ...style
      }}
      onPointerDown={e => { if (!disabled) e.currentTarget.style.transform = 'scale(0.98)'; }}
      onPointerUp={e => { e.currentTarget.style.transform = 'none'; }}
      onPointerLeave={e => { e.currentTarget.style.transform = 'none'; }}
      {...rest}
    >{children}</button>
  );
}
