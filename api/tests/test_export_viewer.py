"""The readable layer inside the export zip.

What is being proved here is not "the files are in the zip". It is that the thing somebody
double-clicks in 2040 still works: that it needs no network, no build step and no module
loader, that it reads exactly the same bytes the machine-readable half does, and that a
body somebody typed cannot break the page that renders it.

The one thing these tests cannot prove is that a browser renders it. That was done by hand
and written up in the pull request; `test_the_page_wires_the_three_files_together` is the
part of it a suite can hold on to.
"""

from __future__ import annotations

import io
import json
import re
import zipfile

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.constants import PROMPT_TOKENS, PRONOUNS
from rascal.services import export as export_service
from test_export import _archive, _download, bucket  # noqa: F401  (bucket is a fixture)

VIEWER_FILES = ("index.html", "assets/app.css", "assets/app.js")
GENERATED_FILES = ("entries.js", "manifest.js")


@pytest.fixture
async def zipped(client: AsyncClient, session: AsyncSession, bucket: str) -> zipfile.ZipFile:  # noqa: F811
    world = await _archive(session)
    response = await _download(client, world)
    return zipfile.ZipFile(io.BytesIO(response.content))


# --- What is in the box ---------------------------------------------------------------


async def test_the_zip_carries_the_viewer_and_the_backup_both(zipped: zipfile.ZipFile) -> None:
    names = set(zipped.namelist())
    for name in VIEWER_FILES + GENERATED_FILES:
        assert name in names, f"{name} is missing from the export"
    # The machine-readable half is untouched by any of this.
    assert "entries.json" in names
    assert "manifest.json" in names


def test_the_viewer_assets_exist_in_the_build() -> None:
    """A packaging change that drops non-Python files fails here, not in somebody's 2040."""
    names = {name for name, _ in export_service.viewer_files()}
    assert names == set(VIEWER_FILES)


# --- One source of truth --------------------------------------------------------------


def _unwrap(script: bytes, variable: str) -> str:
    prefix = f"window.{variable} = ".encode()
    assert script.startswith(prefix), script[:60]
    assert script.endswith(b";\n"), script[-20:]
    return script[len(prefix) : -2].decode("utf-8")


async def test_entries_js_is_entries_json_with_an_assignment_around_it(
    zipped: zipfile.ZipFile,
) -> None:
    """Not 'equivalent' — the same bytes. Two payloads is two things that can disagree."""
    payload = zipped.read("entries.json")
    assert _unwrap(zipped.read("entries.js"), "RASCAL_ENTRIES").encode("utf-8") == payload


async def test_manifest_js_is_manifest_json_with_an_assignment_around_it(
    zipped: zipfile.ZipFile,
) -> None:
    payload = zipped.read("manifest.json")
    assert _unwrap(zipped.read("manifest.js"), "RASCAL_MANIFEST").encode("utf-8") == payload


async def test_the_sealed_letter_is_in_the_viewers_copy_too(zipped: zipfile.ZipFile) -> None:
    """Forking the two files is the one way this design produces a second source of truth."""
    entries = json.loads(_unwrap(zipped.read("entries.js"), "RASCAL_ENTRIES"))
    sealed = [record for record in entries if record["unlock_at_age"] is not None]
    assert len(sealed) == 1
    assert sealed[0]["unlock_at_age"] == 18
    assert "the moon was following the car" in sealed[0]["body"]

    # And the deleted row, which the viewer hides by default but must still be able to show.
    assert any(record["is_deleted"] for record in entries)


def test_a_body_containing_a_closing_script_tag_cannot_end_the_script() -> None:
    """A parent may reasonably write `</script>` in an entry. It must be nine characters."""
    payload = json.dumps([{"body": "he typed </script><script>alert(1)</script> at me"}]).encode()
    wrapped = export_service._as_script(payload, "RASCAL_ENTRIES")

    assert b"</script>" not in wrapped
    assert b"<\\/script>" in wrapped
    # Escaped, and still exactly the same value on the other side.
    assert json.loads(_unwrap(wrapped, "RASCAL_ENTRIES")) == json.loads(payload)


def test_the_javascript_line_terminators_are_escaped() -> None:
    """U+2028 and U+2029 are legal in JSON and were line terminators in JS before ES2019.

    `ensure_ascii=False` writes them into the file raw, which is correct for `entries.json`
    and a syntax error for `entries.js` on an older engine.
    """
    body = "before\u2028middle\u2029after"
    payload = json.dumps({"body": body}, ensure_ascii=False).encode("utf-8")
    assert "\u2028".encode() in payload  # the hazard is real before it is escaped

    wrapped = export_service._as_script(payload, "RASCAL_MANIFEST")

    assert "\u2028".encode() not in wrapped
    assert "\u2029".encode() not in wrapped
    assert json.loads(_unwrap(wrapped, "RASCAL_MANIFEST"))["body"] == body


# --- 2040 ------------------------------------------------------------------------------


def _shipped() -> dict[str, str]:
    """The shipped files, verbatim."""
    return {name: path.read_text(encoding="utf-8") for name, path in export_service.viewer_files()}


#: `/* … */`, `<!-- … -->`, and `//` to end of line — but not the `//` in `file://`, which
#: is why the scheme separator is excluded rather than the whole sequence.
_COMMENTS = re.compile(r"/\*.*?\*/|<!--.*?-->|(?<!:)//[^\n]*", re.DOTALL)


def _code() -> dict[str, str]:
    """The shipped files with their comments removed.

    Every assertion below about what the viewer *does* runs against this, because the file
    that explains why it must never use `innerHTML` would otherwise fail the test that
    checks it never uses `innerHTML`. The one assertion that runs against the verbatim text
    is the network one, deliberately: a URL is a tripwire even in a comment.
    """
    return {name: _COMMENTS.sub("", text) for name, text in _shipped().items()}


def test_nothing_in_the_viewer_reaches_the_network() -> None:
    """The assertion the whole design rests on. A CDN in here is a dead archive in 2040.

    Anything absolute — a stylesheet, a font, an analytics beacon, an `xmlns` on an inline
    SVG — trips this. So does a protocol-relative `//host/path`, which is the version of
    this mistake that does not contain the word `http`.
    """
    offenders: list[str] = []
    for name, text in _shipped().items():
        for line_no, line in enumerate(text.splitlines(), start=1):
            for pattern in ("http://", "https://", 'src="//', "src='//", 'href="//', "href='//"):
                if pattern in line:
                    offenders.append(f"{name}:{line_no}: {line.strip()}")
    detail = "\n".join(offenders)
    assert offenders == [], f"the viewer must not reference anything off this machine:\n{detail}"


def test_the_viewer_fetches_nothing_at_runtime() -> None:
    """`fetch` and `XMLHttpRequest` are blocked from a file:// origin. Neither may appear."""
    script = _code()["assets/app.js"]
    for banned in ("fetch(", "XMLHttpRequest", "importScripts", "navigator.sendBeacon"):
        assert banned not in script, f"{banned} cannot work from a file path"


def test_the_page_does_not_use_module_scripts() -> None:
    """A module is fetched under CORS rules a file:// page cannot satisfy — a blank page."""
    html = _code()["index.html"]
    assert 'type="module"' not in html
    assert "type='module'" not in html


def test_the_viewer_uses_system_fonts_and_bundles_none() -> None:
    css = _code()["assets/app.css"]
    assert "-apple-system, BlinkMacSystemFont" in css
    assert "@font-face" not in css
    assert "@import" not in css
    # url() is how a font, an image, or a tracking pixel would sneak back in.
    assert "url(" not in css


def test_every_reference_in_the_page_is_relative() -> None:
    html = _code()["index.html"]
    for ref in re.findall(r'(?:src|href)="([^"]*)"', html):
        assert not ref.startswith("/"), f"{ref} is absolute and will not resolve from a zip"
        assert "://" not in ref, ref


def test_the_page_wires_the_three_files_together() -> None:
    """The load order is load-bearing: the data has to exist before app.js runs."""
    html = _code()["index.html"]
    order = [
        html.index('src="manifest.js"'),
        html.index('src="entries.js"'),
        html.index('src="assets/app.js"'),
    ]
    assert order == sorted(order)
    assert 'href="assets/app.css"' in html


def test_the_page_says_where_the_archive_is_when_javascript_is_off() -> None:
    """Someone in 2040 with a locked-down browser must not conclude the archive is empty."""
    html = _shipped()["index.html"]
    assert "<noscript>" in html
    noscript = html[html.index("<noscript>") : html.index("</noscript>")]
    assert "entries.json" in noscript
    assert "media" in noscript


def test_the_viewer_builds_its_dom_rather_than_assigning_markup() -> None:
    """An entry body is user-written text. It renders as text or it is a defect."""
    script = _code()["assets/app.js"]
    assert "innerHTML" not in script
    assert "outerHTML" not in script
    assert "document.write" not in script


def test_the_viewer_asserts_on_the_format_it_was_written_for() -> None:
    script = _code()["assets/app.js"]
    assert "rascal-export" in script
    assert f"SUPPORTED_VERSION = {export_service.EXPORT_FORMAT_VERSION}" in script


def test_the_viewer_renders_dates_in_the_family_timezone() -> None:
    """occurred_at is serialized in UTC. The reader's own zone would move evenings a day."""
    script = _code()["assets/app.js"]
    assert "family_timezone" in script
    assert "timeZone" in script


def test_a_card_is_not_a_button() -> None:
    """A card contains `<audio controls>`. Interactive content inside a button is invalid,
    and the way that bites is a play button that cannot be pressed on a browser that
    tightened up. The card is a div with a role, and the keyboard is wired by hand."""
    script = _code()["assets/app.js"]
    assert 'el("div", "card")' in script
    assert '"role", "link"' in script
    assert '"tabindex", "0"' in script
    assert 'addEventListener("keydown"' in script


def test_pressing_play_does_not_also_open_the_entry() -> None:
    """The delegated click walks up from the target and stops at the element that owns it."""
    script = _code()["assets/app.js"]
    assert "OWNS_ITS_CLICK" in script
    for tag in ("AUDIO", "VIDEO", "A"):
        assert f"{tag}: true" in script


def test_a_file_that_will_not_load_degrades_to_its_metadata() -> None:
    """Two ways for bytes to be absent: the export never had them, or the folder changed
    afterwards. Both render as words. A broken-image icon reads as data loss, and neither
    of these is that."""
    script = _code()["assets/app.js"]
    assert "degradeOnError" in script
    assert 'addEventListener("error"' in script
    assert 'absentBlock(item, "folder")' in script
    assert 'absentBlock(item, "export")' in script


def test_the_viewer_writes_no_copy_that_assumes_the_childs_gender() -> None:
    """Client-side strings are neutral and stay that way.

    The viewer ships a pronoun table as of phase 24, and `he`, `his` and `her` are *data*
    inside it — the one place in the viewer those words belong. Everything else is copy,
    and copy addresses the child in the second person and never guesses. So the table is
    cut out by name and the rest is checked as strictly as it was before, rather than the
    check being loosened until the table fits through it.
    """
    files = dict(_code())
    table = re.search(r"  var PRONOUN_COLUMN = \{.*?\n  \};\n", files["assets/app.js"], re.S)
    assert table, "the pronoun table was renamed or reshaped; this test cuts it out by name"
    files["assets/app.js"] = files["assets/app.js"].replace(table.group(0), "")

    text = "\n".join(files.values()).lower()
    for word in (" he ", " his ", " him ", " she ", " her ", " hers "):
        assert word not in text, f"{word.strip()!r} appears in a shipped viewer string"


def test_the_viewer_implements_the_whole_token_contract() -> None:
    """Thirteen tokens and three columns, or an archive prints braces at somebody's kitchen
    table in 2040.

    The contract is `docs/api-contract.md`; `PROMPT_TOKENS` is the same list the seed loader
    validates against, so a token added there without being added here fails now rather than
    on the next export.
    """
    script = _code()["assets/app.js"]
    table = re.search(r"var PRONOUN_COLUMN = \{.*?\n  \};", script, re.S).group(0)
    for token in PROMPT_TOKENS:
        if token == "name":
            continue  # not a pronoun; it is read off the manifest's child block
        assert re.search(rf"\b{token}:", table), f"{{{token}}} is missing from the viewer table"
    for pronoun in PRONOUNS:
        assert f'"{pronoun}"' in table, f"the {pronoun} column is missing from the viewer table"


def test_every_place_the_viewer_shows_a_prompt_renders_its_tokens() -> None:
    """Three sites, and the search index is the one that is easy to forget.

    A card and the detail pane are visible the moment anything is wrong. The haystack is
    not: miss it and the archive looks right but cannot be searched for the words it is
    actually showing.
    """
    script = _code()["assets/app.js"]
    lines = re.findall(r"[^\n]*raw\.prompt\.body[^\n]*", script)
    guards = [line for line in lines if "raw.prompt && raw.prompt.body" in line]
    rendered = [line for line in lines if "renderTokens(String(raw.prompt.body" in line]

    # Every mention of the raw body is either a presence check or a rendered read. A third
    # kind of line is the bug this is looking for.
    assert len(guards) + len(rendered) == len(lines), lines
    assert len(rendered) == 3, rendered
