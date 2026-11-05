package com.officeflow;

import java.util.ArrayList;
import java.util.List;

public final class Csv {
  private Csv() {}

  public static List<List<String>> parse(String source) {
    if (source.length() > 200_000)
      throw new IllegalArgumentException("CSV must be smaller than 200 KB.");
    if (source.startsWith("\uFEFF")) source = source.substring(1);
    List<List<String>> rows = new ArrayList<>();
    List<String> row = new ArrayList<>();
    StringBuilder field = new StringBuilder();
    boolean quoted = false, closed = false;
    for (int i = 0; i <= source.length(); i++) {
      char c = i == source.length() ? '\0' : source.charAt(i);
      if (quoted) {
        if (c == '\0') throw new IllegalArgumentException("Unclosed CSV quote.");
        if (c == '"' && i + 1 < source.length() && source.charAt(i + 1) == '"') {
          field.append('"');
          i++;
        } else if (c == '"') {
          quoted = false;
          closed = true;
        } else field.append(c);
      } else if (c == ',' || c == '\n' || c == '\r' || c == '\0') {
        row.add(field.toString());
        field.setLength(0);
        closed = false;
        if (c != ',') {
          if (row.stream().anyMatch(s -> !s.isBlank())) rows.add(row);
          row = new ArrayList<>();
          if (c == '\r' && i + 1 < source.length() && source.charAt(i + 1) == '\n') i++;
        }
      } else if (c == '"') {
        if (field.length() > 0 || closed)
          throw new IllegalArgumentException("Unexpected CSV quote.");
        quoted = true;
      } else {
        if (closed) throw new IllegalArgumentException("Text after CSV quote.");
        field.append(c);
      }
    }
    return rows;
  }
}
