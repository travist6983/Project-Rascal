"""The admin console's static assets.

A package rather than a bare directory so `src/rascal/admin/static/` is included in the wheel
by hatchling's `packages = ["src/rascal"]` — a directory with no `__init__.py` is not, and
the console would 404 in the built image while working perfectly from a checkout.
"""
