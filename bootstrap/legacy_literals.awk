# Rewrites the lowercase literals true, false, and none as the capitalized
# spellings that the frozen stage 1 compiler parses. It copies strings and
# comments unchanged, so printed values and documentation keep the lowercase
# spelling. Stage 1 gets its own core and library text and the sources of stage
# 2 in this form; stage 2 and later compile the lowercase sources directly.
BEGIN {
    triple = ""
}
{
    line = $0
    out = ""
    i = 1
    n = length(line)
    while (i <= n) {
        if (triple != "") {
            at = index(substr(line, i), triple)
            if (at) {
                out = out substr(line, i, at + 2)
                i += at + 2
                triple = ""
            } else {
                out = out substr(line, i)
                i = n + 1
            }
            continue
        }
        c = substr(line, i, 1)
        if (c == "#") {
            out = out substr(line, i)
            i = n + 1
        } else if (c == "\"" || c == "\047") {
            if (substr(line, i, 3) == c c c) {
                out = out c c c
                triple = c c c
                i += 3
            } else {
                out = out c
                i++
                while (i <= n) {
                    d = substr(line, i, 1)
                    out = out d
                    if (d == "\\") {
                        if (i < n) {
                            out = out substr(line, i + 1, 1)
                            i += 2
                        } else {
                            i++
                        }
                    } else if (d == c) {
                        i++
                        break
                    } else {
                        i++
                    }
                }
            }
        } else if (c ~ /[A-Za-z_]/) {
            j = i
            while (j <= n && substr(line, j, 1) ~ /[A-Za-z0-9_]/) {
                j++
            }
            word = substr(line, i, j - i)
            if (word == "true") {
                word = "True"
            } else if (word == "false") {
                word = "False"
            } else if (word == "none") {
                word = "None"
            }
            out = out word
            i = j
        } else {
            out = out c
            i++
        }
    }
    print out
}
