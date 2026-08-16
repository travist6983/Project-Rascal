Bottom sheet — the only modal shape in RASCAL (centered dialogs are OS chrome only).

```jsx
<Sheet open={asking} onScrimClick={dismiss}>
  <h2>Save this to Milo's archive.</h2>
  <Button tone="dark" radius="14px">Sign in with Apple</Button>
</Sheet>
```

28px top corners, ink scrim at 40%, slides up on `rascal-sheet-up`. A sheet
always leaves the card it refers to visible above it.
