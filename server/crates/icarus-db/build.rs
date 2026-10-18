// `sqlx::migrate!` embeds the migration files at compile time. Watching the directory makes
// cargo rebuild this crate when a migration is added, so the binary never runs a stale list.
fn main() {
    println!("cargo:rerun-if-changed=../../migrations");
}
