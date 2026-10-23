//! Stage 0 of the Willow bootstrap. See agents/bootstrap.md.
//!
//! Usage: willow0 build FILE.wlo -o OUTPUT
//!        willow0 compile FILE.wlo -o OUTPUT.ssa

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("build" | "compile") => {
            eprintln!("willow0: not implemented");
            ExitCode::from(2)
        }
        _ => {
            eprintln!("usage: willow0 build FILE.wlo -o OUTPUT\n       willow0 compile FILE.wlo -o OUTPUT.ssa");
            ExitCode::from(2)
        }
    }
}
