local lexer = require("compiler.lexer")
local diag = require("compiler.diag")

local function eq(expected, actual)
  if expected ~= actual then
    error(string.format("expected %q, got %q", tostring(expected), tostring(actual)), 2)
  end
end

local function kinds(source)
  local result = {}
  for _, token in ipairs(lexer.lex(source)) do
    result[#result + 1] = token.kind
  end
  return table.concat(result, " ")
end

local function lex_error(source)
  local ok, err = pcall(lexer.lex, source)
  if ok then
    error("expected a lexical error", 2)
  end
  if not diag.is(err) then
    error(err, 0)
  end
  return string.format("%d:%d: %s", err[1].span.line, err[1].span.col, err[1].message)
end

local function single(source)
  local tokens = lexer.lex(source)
  return tokens[1]
end

return {
  tokens_for_a_function = function()
    local source = "def inc(x: int) -> int:\n    return x + 1\n"
    eq("def NAME ( NAME : int ) -> int : NEWLINE INDENT return NAME + INT NEWLINE DEDENT EOF", kinds(source))
    local tokens = lexer.lex(source)
    eq("inc", tokens[2].value)
    eq("x", tokens[4].value)
    eq(1, tokens[16].value)
  end,

  crlf_matches_lf = function()
    local lf = "def f() -> None:\n    pass\n"
    local crlf = "def f() -> None:\r\n    pass\r\n"
    eq(kinds(lf), kinds(crlf))
    local newline = lexer.lex(crlf)[8]
    eq("NEWLINE", newline.kind)
    eq("\r\n", crlf:sub(newline.span.first, newline.span.last))
    eq(2, lexer.lex(crlf)[10].span.line)
  end,

  bare_cr_rejected = function()
    local message = "bare carriage return; line endings must be LF or CRLF"
    eq("1:6: " .. message, lex_error("x = 1\ry = 2\n"))
    eq("2:4: " .. message, lex_error("x = 1\n# a\rb\n"))
    eq("1:7: " .. message, lex_error("x = 'a\rb'\n"))
  end,

  invalid_utf8_rejected = function()
    eq("2:5: invalid UTF-8", lex_error("x = 1\n# é \255\n"))
    eq("1:6: invalid UTF-8", lex_error("x = '\192\128'\n"))
    eq("1:6: invalid UTF-8", lex_error("x = '\237\160\128'\n"))
  end,

  columns_count_code_points = function()
    local source = "x = 'héllo' + y\n"
    local tokens = lexer.lex(source)
    eq("héllo", tokens[3].value)
    eq("y", tokens[5].value)
    eq(15, tokens[5].span.col)
    eq(16, tokens[5].span.first)
  end,

  tabs_rejected_outside_strings_and_comments = function()
    local message = "tabs are not allowed outside strings and comments"
    eq("2:1: " .. message, lex_error("def f() -> None:\n\tpass\n"))
    eq("1:4: " .. message, lex_error("x =\t1\n"))
    eq("2:3: " .. message, lex_error("x = 1\n  \t\ny = 2\n"))
    eq("NAME = STRING NEWLINE EOF", kinds("x = '\t'  # \t\n"))
  end,

  blank_and_comment_lines_ignored = function()
    local source = "def f() -> None:\n\n   # odd\n  \n    pass\n      # deeper\n# end\n"
    eq("def NAME ( ) -> None : NEWLINE INDENT pass NEWLINE DEDENT EOF", kinds(source))
  end,

  missing_final_newline = function()
    local source = "def f() -> None:\n    while True:\n        pass"
    eq("def NAME ( ) -> None : NEWLINE INDENT while True : NEWLINE INDENT pass NEWLINE DEDENT DEDENT EOF",
      kinds(source))
  end,

  newlines_inside_parentheses = function()
    local source = "def f() -> None:\n    g(1,\n  2,\n          (3\n),\n    )\n    pass\n"
    eq("def NAME ( ) -> None : NEWLINE INDENT NAME ( INT , INT , ( INT ) , ) NEWLINE pass NEWLINE DEDENT EOF",
      kinds(source))
  end,

  indentation_errors = function()
    eq("2:3: indentation must be a multiple of four spaces", lex_error("def f() -> None:\n  pass\n"))
    eq("2:9: unexpected indent", lex_error("def f() -> None:\n        pass\n"))
  end,

  keywords_and_names = function()
    eq("while True and not NAME int float bool str None lambda NAME NAME NEWLINE EOF",
      kinds("while True and not x_1 int float bool str None lambda print _\n"))
  end,

  integer_literals = function()
    eq(0, single("0").value)
    eq(9007199254740991, single("9007199254740991").value)
    eq("1:5: integer literal has leading zeros", lex_error("x = 007\n"))
    eq("1:5: integer literal out of range", lex_error("x = 9007199254740992\n"))
    eq("1:5: integer literal out of range", lex_error("x = 12345678901234567890\n"))
    eq("1:5: invalid number literal '0x1F'", lex_error("x = 0x1F\n"))
    eq("1:5: invalid number literal '1_000'", lex_error("x = 1_000\n"))
  end,

  float_literals = function()
    eq("FLOAT", single("1.0").kind)
    eq(1, single("1.0").value)
    eq(0.25, single("0.25").value)
    eq(1e9, single("1e9").value)
    eq(2.5e-3, single("2.5e-3").value)
    eq(1e5, single("1E+5").value)
    eq(0.1, single("0.1").value)
    eq("1:5: invalid number literal '1.'", lex_error("x = 1.\n"))
    eq("1:5: invalid number literal '1.e5'", lex_error("x = 1.e5\n"))
    eq("1:5: invalid number literal '1e'", lex_error("x = 1e\n"))
    eq("1:5: invalid number literal '1.5.2'", lex_error("x = 1.5.2\n"))
    eq("1:5: float literal has leading zeros", lex_error("x = 01.5\n"))
    eq("1:5: float literal has leading zeros", lex_error("x = 00e1\n"))
    eq("1:5: float literal out of range", lex_error("x = 1e400\n"))
  end,

  string_literals = function()
    eq('a"b', single("'a\"b'").value)
    eq("a'b", single("\"a'b\"").value)
    eq("\\ ' \" \n \r \t", single([['\\ \' \" \n \r \t']]).value)
    eq("日本語 ✓", single("'日本語 ✓'").value)
    eq("1:7: unknown escape sequence '\\q'", lex_error("x = 'a\\qb'\n"))
    eq("1:5: unterminated string literal", lex_error("x = 'ab\ncd'\n"))
    eq("1:5: unterminated string literal", lex_error("x = 'ab\\\ncd'\n"))
    eq("1:5: unterminated string literal", lex_error("x = 'abc"))
  end,

  operators = function()
    local text = "-> == != <= >= < > = + - * / // % | ( ) , :"
    eq(text .. " NEWLINE EOF", kinds(text))
  end,

  brackets_and_braces = function()
    eq("NAME = [ INT , { STRING : NAME . NAME } ] NEWLINE EOF", kinds("x = [1,\n  {'a':\n    b.c}\n]\n"))
  end,

  unsupported_operators = function()
    for operator in ("/= //= %= |= ** += := & ^ ~ << >>"):gmatch("%S+") do
      eq("1:3: unsupported operator '" .. operator .. "'", lex_error("a " .. operator .. " b\n"))
    end
  end,

  unexpected_characters = function()
    eq("1:5: unexpected character '@'", lex_error("x = @\n"))
    eq("1:5: unexpected character 'é'", lex_error("x = é\n"))
  end,
}
