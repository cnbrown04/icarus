//! The checked-in OpenAPI document must match what the code generates (PLAN.md §17.2).

use std::path::PathBuf;

#[test]
fn openapi_matches_checked_in_file() {
    let generated = icarus_api::openapi::document()
        .to_yaml()
        .expect("the OpenAPI document serialises to YAML");
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../shared/openapi.yaml");

    if std::env::var("UPDATE_OPENAPI").as_deref() == Ok("1") {
        std::fs::write(&path, &generated).expect("write shared/openapi.yaml");
        return;
    }
    let checked_in = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(
        checked_in == generated,
        "shared/openapi.yaml is out of date with the code. Regenerate with: \
         UPDATE_OPENAPI=1 cargo test -p icarus-api --test openapi"
    );
}
