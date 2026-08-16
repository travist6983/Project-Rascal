/**
 * The pill that names what kind of thing a prompt or entry is.
 */
export interface BadgeProps {
  /** Sets fill + ink + default label. photo/voice are terracotta; question/wrote are periwinkle; did is sage. */
  kind?: 'photo' | 'voice' | 'question' | 'wrote' | 'did';
  /** Drop the fill and keep only the colored label — used inside already-tinted timeline cards. */
  bare?: boolean;
  /** Override the label text. Uppercase only. */
  children?: React.ReactNode;
  style?: React.CSSProperties;
}
export function Badge(props: BadgeProps): JSX.Element;
