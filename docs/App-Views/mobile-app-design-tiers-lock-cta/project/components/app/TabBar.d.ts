/**
 * The floating tab bar: four word-labels around an overhanging terracotta FAB.
 * @startingPoint section="App" subtitle="Floating tab bar with center FAB" viewport="700x140"
 */
export interface TabBarProps {
  /** Exactly four labels. The center slot is the FAB, not a tab. */
  items?: string[];
  active?: string;
  onSelect?: (label: string) => void;
  onAdd?: () => void;
  style?: React.CSSProperties;
}
export function TabBar(props: TabBarProps): JSX.Element;
