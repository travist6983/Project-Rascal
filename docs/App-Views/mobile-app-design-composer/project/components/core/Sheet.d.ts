/**
 * Bottom sheet over a scrim. The system's only modal shape.
 */
export interface SheetProps {
  open?: boolean;
  onScrimClick?: () => void;
  children?: React.ReactNode;
  style?: React.CSSProperties;
}
export function Sheet(props: SheetProps): JSX.Element | null;
