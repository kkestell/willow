//! Stage 0 of the Willow bootstrap. See agents/bootstrap.md.
//!
//! Usage: willow0 build FILE.wlo -o OUTPUT
//!        willow0 compile FILE.wlo -o OUTPUT.ssa

mod check;
mod emit;
mod lexer;
mod parser;
mod types;

use std::path::Path;
use std::process::{Command, ExitCode};

/// The core module, compiled into every program.
const CORE: &str = include_str!("../../core/core.wlo");
const CORE_PATH: &str = "bootstrap/core/core.wlo";

const USAGE: &str =
    "usage: willow0 build FILE.wlo -o OUTPUT\n       willow0 compile FILE.wlo -o OUTPUT.ssa";

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Pos {
    pub line: u32,
    pub col: u32,
}

/// A compile-time error in the spec §13 format.
pub struct Diag {
    path: String,
    pos: Pos,
    message: String,
}

impl Diag {
    pub fn new(path: &str, pos: Pos, message: impl Into<String>) -> Diag {
        Diag {
            path: path.to_string(),
            pos,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for Diag {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(
            f,
            "{}:{}:{}: error: {}",
            self.path, self.pos.line, self.pos.col, self.message
        )
    }
}

fn load(name: &str, path: &str, source: &[u8]) -> Result<parser::Module, Diag> {
    parser::parse(name, path, lexer::lex(path, source)?)
}

fn compile(path: &str) -> Result<String, String> {
    let source = std::fs::read(path).map_err(|e| format!("willow0: {path}: {e}"))?;
    let name = Path::new(path)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let valid = name.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    if !valid || name == "core" {
        return Err(format!("willow0: {path}: '{name}' cannot be a module name"));
    }
    let modules = vec![
        load(name, path, &source).map_err(|d| d.to_string())?,
        load("core", CORE_PATH, CORE.as_bytes()).map_err(|d| d.to_string())?,
    ];
    let program = check::check(&modules).map_err(|d| d.to_string())?;
    Ok(emit::emit(&program))
}

fn qbe_target() -> Result<&'static str, String> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => Ok("arm64_apple"),
        ("macos", "x86_64") => Ok("amd64_apple"),
        ("linux", "aarch64") => Ok("arm64"),
        ("linux", "x86_64") => Ok("amd64_sysv"),
        (os, arch) => Err(format!("willow0: unsupported host {os} {arch}")),
    }
}

/// The compiler flags that link libgc.
fn gc_flags() -> Vec<String> {
    let output = Command::new("pkg-config")
        .args(["--cflags", "--libs", "bdw-gc"])
        .output();
    match output {
        Ok(output) if output.status.success() => String::from_utf8_lossy(&output.stdout)
            .split_whitespace()
            .map(String::from)
            .collect(),
        _ => vec!["-lgc".to_string()],
    }
}

fn run(command: &mut Command) -> Result<(), String> {
    let program = command.get_program().to_string_lossy().into_owned();
    match command.status() {
        Ok(status) if status.success() => Ok(()),
        Ok(_) => Err(format!("willow0: {program} failed")),
        Err(e) => Err(format!("willow0: cannot run {program}: {e}")),
    }
}

fn build(il: &str, output: &str) -> Result<(), String> {
    let target = qbe_target()?;
    let dir = std::env::temp_dir().join(format!("willow0-{}", std::process::id()));
    std::fs::create_dir(&dir).map_err(|e| format!("willow0: {}: {e}", dir.display()))?;
    let ssa = dir.join("program.ssa");
    let asm = dir.join("program.s");
    let result = std::fs::write(&ssa, il)
        .map_err(|e| format!("willow0: {}: {e}", ssa.display()))
        .and_then(|_| {
            run(Command::new("qbe")
                .args(["-t", target, "-o"])
                .arg(&asm)
                .arg(&ssa))
        })
        .and_then(|_| {
            run(Command::new("cc")
                .arg("-o")
                .arg(output)
                .arg(&asm)
                .args(gc_flags())
                .arg("-lm"))
        });
    let _ = std::fs::remove_dir_all(&dir);
    result
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (command, file, output) = match args.as_slice() {
        [command, file, flag, output]
            if (command == "build" || command == "compile") && flag == "-o" =>
        {
            (command, file, output)
        }
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    let result = compile(file).and_then(|il| {
        if command == "compile" {
            std::fs::write(output, il).map_err(|e| format!("willow0: {output}: {e}"))
        } else {
            build(&il, output)
        }
    });
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}
