Floating tab bar — words, not icons, around a center FAB.

```jsx
<TabBar active="Today" onSelect={setTab} onAdd={openCapture} />
```

RASCAL has no icon set; the tabs are 11px uppercase Nunito labels. Do not add
glyphs above them. Its parent must be `position: relative` and any scroller
under it needs `110px` of bottom padding.
