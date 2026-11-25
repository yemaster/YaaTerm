use alacritty_terminal::event::VoidListener;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::test::TermSize;
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::vte::ansi::Processor;
use std::{env, fs, time::Instant};

fn main() {
    let mut args = env::args().skip(1);
    let input = fs::read(args.next().unwrap()).unwrap();
    let repeats: usize = args.next().unwrap().parse().unwrap();
    let config = Config { scrolling_history: 0, ..Config::default() };
    let mut term = Term::new(config, &TermSize::new(100, 32), VoidListener);
    let mut parser: Processor = Processor::new();
    let start = Instant::now();
    for _ in 0..repeats {
        parser.advance(&mut term, &input);
    }
    println!("{:.9}", start.elapsed().as_secs_f64());
    for y in 0..32 {
        for x in 0..100 {
            print!("{:x} ", term.grid()[Line(y)][Column(x)].c as u32);
        }
        println!();
    }
}
