/**
 * The only button in the system. Pill by default; full-width in app contexts.
 * @startingPoint section="Core" subtitle="Pill buttons in every tone" viewport="700x220"
 */
export interface ButtonProps {
  /** primary = terracotta (one per screen). written = periwinkle, for write/text actions. secondary = hairline outline. dark = ink, for Sign in with Apple. quiet = underlined text link. */
  tone?: 'primary' | 'written' | 'secondary' | 'dark' | 'quiet';
  size?: 'lg' | 'md' | 'sm';
  /** Full width. True by default — app buttons always span the gutter. */
  block?: boolean;
  disabled?: boolean;
  /** Override the pill radius. Only for OS-chrome buttons (14px). */
  radius?: string;
  children?: React.ReactNode;
  onClick?: () => void;
  style?: React.CSSProperties;
}
export function Button(props: ButtonProps): JSX.Element;
