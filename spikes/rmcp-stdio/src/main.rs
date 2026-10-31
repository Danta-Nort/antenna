// SPDX-License-Identifier: AGPL-3.0-only
//! Spike e): rmcp 3.5, a minimal stdio MCP server with one tool.
//! Check: `./run.sh` feeds initialize + notifications/initialized + tools/list + tools/call into stdin.

use rmcp::{
    ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    tool, tool_handler, tool_router,
    transport::stdio,
};
use schemars::JsonSchema;
use serde::Deserialize;

#[derive(Deserialize, JsonSchema)]
struct GetTrustRequest {
    /// Contact name within the link
    contact: String,
}

#[derive(Debug, Clone)]
struct XMcp {
    tool_router: ToolRouter<Self>,
}

#[tool_router]
impl XMcp {
    fn new() -> Self {
        Self { tool_router: Self::tool_router() }
    }

    /// Read-only. Owner commands (trust/invite/join/approve...) are physically absent from MCP.
    #[tool(description = "Return the local trust level for a contact (read-only)")]
    async fn get_trust(&self, Parameters(req): Parameters<GetTrustRequest>) -> String {
        format!("spike: contact {:?} has trust level 2 (fake data)", req.contact)
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for XMcp {}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // stdout carries the protocol: logs go only to stderr
    let service = XMcp::new().serve(stdio()).await?;
    service.waiting().await?;
    Ok(())
}
