//! The OpenAPI 3.1 document for the v1 API (PLAN.md §12.1, §17.2).
//!
//! Generated from the `#[utoipa::path]` annotations on the handlers and the `ToSchema` wire types.
//! `shared/openapi.yaml` is the checked-in copy, and the `openapi_matches_checked_in_file` test fails
//! when the two differ. To regenerate after an intended change:
//! `UPDATE_OPENAPI=1 cargo test -p icarus-api --test openapi`.

use utoipa::{
    Modify, OpenApi, ToSchema,
    openapi::{
        Components,
        security::{ApiKey, ApiKeyValue, Http, HttpAuthScheme, SecurityScheme},
    },
};

use crate::routes;

/// RFC 9457 problem document. Handlers build it in `error.rs`; this type only documents it.
#[derive(ToSchema)]
pub struct Problem {
    /// `urn:icarus:problem:<slug>`, where the slug is one of the contract's list.
    #[serde(rename = "type")]
    pub kind: String,
    pub title: String,
    pub status: u16,
    pub detail: String,
    /// The stored entity, on `conflict` responses only.
    #[schema(value_type = Option<Object>)]
    pub current: Option<serde_json::Value>,
}

#[derive(OpenApi)]
#[openapi(
    info(
        title = "Icarus API",
        version = "1.0.0",
        description = "Contract v1 for the Icarus server (shared/api-contract.md). Times are RFC 3339 UTC with Z, except fields ending in _ms (epoch milliseconds). Metrics are estimates, not medical readings."
    ),
    paths(
        crate::healthz,
        crate::readyz,
        routes::auth::login,
        routes::auth::logout,
        routes::me::get_me,
        routes::me::patch_me,
        routes::me::delete_me,
        routes::devices::create_pairing_code,
        routes::devices::pair,
        routes::devices::list,
        routes::devices::revoke,
        routes::devices::put_push_token,
        routes::sync::post_batch,
        routes::sync::get_config,
        routes::sync::get_state,
        routes::metrics::hr,
        routes::metrics::minutes,
        routes::metrics::daily,
        routes::metrics::live,
        routes::alarms::list,
        routes::alarms::create,
        routes::alarms::patch,
        routes::alarms::delete,
        routes::alarms::test,
        routes::dispatches::pending,
        routes::dispatches::list,
        routes::dispatches::ack,
        routes::hooks::list,
        routes::hooks::create,
        routes::hooks::patch,
        routes::hooks::delete,
        routes::hooks::rotate,
        routes::hooks::deliveries,
        routes::ingress::post_signed,
        routes::ingress::post_secret,
        routes::export::export,
        routes::whoop::status,
        routes::whoop::connect,
        routes::whoop::callback,
        routes::whoop::webhook,
        routes::whoop::summary,
        routes::whoop::disconnect,
    ),
    components(schemas(Problem)),
    modifiers(&SecurityAddon),
    tags(
        (name = "Health"),
        (name = "Auth", description = "Website sign-in. No sign-up route: the single user is created with the create-user command."),
        (name = "Me"),
        (name = "Devices"),
        (name = "Sync", description = "Upload from the app, config download and state."),
        (name = "Metrics"),
        (name = "Alarms"),
        (name = "Webhooks", description = "Hook management (website only)."),
        (name = "Webhook ingress", description = "Public. Authenticated by signature or secret URL, not by session or device token."),
        (name = "Data"),
        (name = "WHOOP", description = "Optional. Every route answers 404 unless WHOOP_CLIENT_ID and WHOOP_CLIENT_SECRET are set."),
    )
)]
pub struct ApiDoc;

/// Declares the two credentials, and drops the empty license block the generator adds. Operations
/// list which credential they accept; listing both means either.
struct SecurityAddon;

impl Modify for SecurityAddon {
    fn modify(&self, openapi: &mut utoipa::openapi::OpenApi) {
        openapi.info.license = None;
        let components = openapi.components.get_or_insert_with(Components::new);
        components.add_security_scheme(
            "session",
            SecurityScheme::ApiKey(ApiKey::Cookie(ApiKeyValue::with_description(
                "icarus_session",
                "Website session from POST /v1/auth/login. Non-GET requests also send X-Icarus-CSRF: 1.",
            ))),
        );
        components.add_security_scheme(
            "device",
            SecurityScheme::Http(Http::new(HttpAuthScheme::Bearer)),
        );
    }
}

/// The generated document. `shared/openapi.yaml` is `to_yaml()` of this.
pub fn document() -> utoipa::openapi::OpenApi {
    ApiDoc::openapi()
}
