import { describe, expect, it } from "vitest";
import { columnLetter, parseTsv } from "./tsv";

describe("parseTsv", () => {
  it("splits tabs and lines", () => {
    expect(parseTsv("a\tb\nc\td\n")).toEqual([
      ["a", "b"],
      ["c", "d"],
    ]);
  });

  it("handles CRLF and pads short rows", () => {
    expect(parseTsv("a\tb\r\nc\r\n")).toEqual([
      ["a", "b"],
      ["c", ""],
    ]);
  });

  it("keeps empty cells and drops empty rows", () => {
    expect(parseTsv("a\t\tc\n\t\t\n\tb\t")).toEqual([
      ["a", "", "c"],
      ["", "b", ""],
    ]);
  });

  it("reads quoted cells like Google Sheets writes them", () => {
    expect(parseTsv('"two\nlines"\t"say ""hi"""\tplain\n')).toEqual([
      ["two\nlines", 'say "hi"', "plain"],
    ]);
  });

  it("leaves quotes alone when the cell isn't fully quoted", () => {
    expect(parseTsv('"Pepe" Pérez\tx')).toEqual([['"Pepe" Pérez', "x"]]);
  });

  it("keeps spaces and accents", () => {
    expect(parseTsv(" María José \tÑuñez")).toEqual([[" María José ", "Ñuñez"]]);
  });
});

describe("columnLetter", () => {
  it("names columns like a spreadsheet", () => {
    expect([0, 1, 25, 26, 27, 51, 52].map(columnLetter)).toEqual([
      "A", "B", "Z", "AA", "AB", "AZ", "BA",
    ]);
  });
});
