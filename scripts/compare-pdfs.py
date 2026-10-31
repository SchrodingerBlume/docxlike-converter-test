"""Assert two PDFs have identical painted text and rule geometry."""
import sys

import pymupdf


def main() -> None:
    left, right = sys.argv[1:3]
    with pymupdf.open(left) as a, pymupdf.open(right) as b:
        assert len(a) == len(b), (len(a), len(b))
        for number, (x, y) in enumerate(zip(a, b), 1):
            assert x.rect == y.rect, (number, x.rect, y.rect)
            assert x.get_texttrace() == y.get_texttrace(), f"text differs on page {number}"
            assert x.get_drawings() == y.get_drawings(), f"rules differ on page {number}"
    print("identical painted geometry")


if __name__ == "__main__":
    main()
