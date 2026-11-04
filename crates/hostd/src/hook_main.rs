fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    hostd::run_hook(&arguments);
}
