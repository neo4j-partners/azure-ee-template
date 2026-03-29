package com.neo4j.keycloak;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jwt.SignedJWT;

import java.io.IOException;
import java.net.ConnectException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;

/**
 * Keycloak test client — acquires a token via client credentials and displays decoded claims.
 *
 * Run with:
 *     ./mvnw compile exec:java                              # local defaults
 *     ./mvnw compile exec:java -Dexec.args="--azure"        # Azure deployment
 */
public class KeycloakTestClient {

    private static final String DEFAULT_SERVER_URL = "http://localhost:8080";
    private static final String DEFAULT_REALM = "neo4j";
    private static final String DEFAULT_CLIENT_ID = "neo4j-client";
    private static final String DEFAULT_CLIENT_SECRET = "neo4j-client-secret";

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final HttpClient HTTP = HttpClient.newHttpClient();

    public static void main(String[] args) throws Exception {
        var config = parseArgs(args);

        var serverUrl = config.get("serverUrl");
        var realm = config.get("realm");
        var clientId = config.get("clientId");
        var clientSecret = config.get("clientSecret");
        var isAzure = "true".equals(config.get("azure"));

        System.out.println("Keycloak server: " + serverUrl);
        System.out.println("Realm:           " + realm);
        System.out.println("Client ID:       " + clientId);
        if (isAzure) {
            System.out.println("Source:          keycloak-infra/.deployment.json");
        } else if (".env".equals(config.get("source"))) {
            System.out.println("Source:          .env");
        }
        System.out.println();

        // Check Keycloak is reachable via OIDC discovery
        var discoveryUrl = serverUrl + "/realms/" + realm + "/.well-known/openid-configuration";
        System.out.println("Discovery URL: " + discoveryUrl);

        Map<String, Object> discovery;
        try {
            discovery = httpGet(discoveryUrl);
            System.out.println("Keycloak discovery endpoint is reachable");
        } catch (ConnectException e) {
            System.out.println("ERROR: Cannot connect to Keycloak at " + serverUrl);
            if (isAzure) {
                System.out.println("Is the Azure Container App running?");
            } else {
                System.out.println("Is Keycloak running? Start it with:");
                System.out.println();
                System.out.println("  docker run -d --name keycloak -p 8080:8080 \\");
                System.out.println("    -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin \\");
                System.out.println("    -v $(pwd)/realm-export.json:/opt/keycloak/data/import/realm-export.json \\");
                System.out.println("    quay.io/keycloak/keycloak:latest start-dev --import-realm");
            }
            System.exit(1);
            return;
        } catch (HttpErrorException e) {
            System.out.println("ERROR: Keycloak returned " + e.statusCode);
            System.out.println("Does the realm '" + realm + "' exist?");
            System.exit(1);
            return;
        }
        System.out.println();

        // Display discovery endpoint fields that Neo4j consumes
        System.out.println("=== Discovery endpoint fields (used by Neo4j) ===");
        System.out.println("  issuer:         " + discovery.get("issuer"));
        System.out.println("  token_endpoint: " + discovery.get("token_endpoint"));
        System.out.println("  jwks_uri:       " + discovery.get("jwks_uri"));
        System.out.println();

        // Acquire token via client credentials grant
        System.out.println("Acquiring token via client credentials grant...");

        Map<String, Object> tokenResponse;
        try {
            tokenResponse = acquireToken(
                    discovery.get("token_endpoint").toString(), clientId, clientSecret);
        } catch (HttpErrorException e) {
            System.out.println("ERROR: Token acquisition failed with status " + e.statusCode);
            System.out.println("Response: " + e.responseBody);
            System.exit(1);
            return;
        }

        var accessToken = tokenResponse.get("access_token").toString();
        System.out.println("Token acquired (type: " + tokenResponse.get("token_type")
                + ", expires_in: " + tokenResponse.get("expires_in") + "s)");
        System.out.println();

        // Decode and display all claims
        var claims = decodeJwt(accessToken);
        System.out.println("=== Full decoded JWT claims ===");
        System.out.println(MAPPER.writerWithDefaultPrettyPrinter().writeValueAsString(claims));
        System.out.println();

        // Highlight claims relevant to Neo4j OIDC integration
        printClaims(claims, clientId);

        // Raw token for manual testing
        System.out.println("=== Raw access token ===");
        System.out.println(accessToken);

        // Connect to Neo4j via JDBC using bearer token
        var neo4jUri = config.get("neo4jUri");
        if (neo4jUri != null) {
            System.out.println();
            connectToNeo4j(neo4jUri, accessToken);
        } else {
            System.out.println();
            System.out.println("No NEO4J_URI configured — skipping JDBC connection test.");
            System.out.println("Set NEO4J_URI in .env or pass --neo4j-uri=bolt://host:7687");
        }
    }

    private static Map<String, String> parseArgs(String[] args) throws Exception {
        var config = new HashMap<String, String>();
        boolean isAzure = false;
        String serverUrl = null, realm = null, clientId = null, clientSecret = null, neo4jUri = null;

        for (var arg : args) {
            if ("--azure".equals(arg)) {
                isAzure = true;
            } else if (arg.startsWith("--server-url=")) {
                serverUrl = arg.substring("--server-url=".length());
            } else if (arg.startsWith("--realm=")) {
                realm = arg.substring("--realm=".length());
            } else if (arg.startsWith("--client-id=")) {
                clientId = arg.substring("--client-id=".length());
            } else if (arg.startsWith("--client-secret=")) {
                clientSecret = arg.substring("--client-secret=".length());
            } else if (arg.startsWith("--neo4j-uri=")) {
                neo4jUri = arg.substring("--neo4j-uri=".length());
            }
        }

        // Load .env file if present (script-generated config)
        var env = loadEnvFile();

        Map<String, String> defaults;
        if (isAzure) {
            defaults = loadAzureDeployment();
            config.put("azure", "true");
        } else if (!env.isEmpty()) {
            defaults = Map.of(
                    "serverUrl", env.getOrDefault("KEYCLOAK_URL", DEFAULT_SERVER_URL),
                    "realm", env.getOrDefault("REALM", DEFAULT_REALM),
                    "clientId", env.getOrDefault("CLIENT_ID", DEFAULT_CLIENT_ID),
                    "clientSecret", env.getOrDefault("CLIENT_SECRET", DEFAULT_CLIENT_SECRET)
            );
            config.put("source", ".env");
        } else {
            defaults = Map.of(
                    "serverUrl", DEFAULT_SERVER_URL,
                    "realm", DEFAULT_REALM,
                    "clientId", DEFAULT_CLIENT_ID,
                    "clientSecret", DEFAULT_CLIENT_SECRET
            );
        }

        config.put("serverUrl", serverUrl != null ? serverUrl : defaults.get("serverUrl"));
        config.put("realm", realm != null ? realm : defaults.get("realm"));
        config.put("clientId", clientId != null ? clientId : defaults.get("clientId"));
        config.put("clientSecret", clientSecret != null ? clientSecret : defaults.get("clientSecret"));

        // Neo4j URI: CLI arg > .env > not set
        if (neo4jUri != null) {
            config.put("neo4jUri", neo4jUri);
        } else if (env.containsKey("NEO4J_URI")) {
            config.put("neo4jUri", env.get("NEO4J_URI"));
        }

        return config;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, String> loadAzureDeployment() throws IOException {
        var deploymentPath = Path.of("../keycloak-infra/.deployment.json");
        if (!Files.exists(deploymentPath)) {
            System.out.println("ERROR: Deployment file not found: " + deploymentPath.toAbsolutePath());
            System.out.println("Deploy Keycloak to Azure first (see keycloak-infra/README.md)");
            System.exit(1);
        }

        var data = MAPPER.readValue(Files.readString(deploymentPath),
                new TypeReference<Map<String, Object>>() {});
        var oidc = (Map<String, Object>) data.get("oidc");

        return Map.of(
                "serverUrl", data.get("keycloak_url").toString(),
                "realm", DEFAULT_REALM,
                "clientId", oidc.get("client_id").toString(),
                "clientSecret", oidc.get("client_secret").toString()
        );
    }

    private static Map<String, Object> httpGet(String url) throws Exception {
        var request = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .GET()
                .build();

        var response = HTTP.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() >= 400) {
            throw new HttpErrorException(response.statusCode(), response.body());
        }
        return MAPPER.readValue(response.body(), new TypeReference<>() {});
    }

    private static Map<String, Object> acquireToken(String tokenEndpoint, String clientId, String clientSecret)
            throws Exception {
        var formBody = "grant_type=" + encode("client_credentials")
                + "&client_id=" + encode(clientId)
                + "&client_secret=" + encode(clientSecret);

        var request = HttpRequest.newBuilder()
                .uri(URI.create(tokenEndpoint))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofString(formBody))
                .build();

        var response = HTTP.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() >= 400) {
            throw new HttpErrorException(response.statusCode(), response.body());
        }
        return MAPPER.readValue(response.body(), new TypeReference<>() {});
    }

    private static String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }

    private static Map<String, Object> decodeJwt(String token) throws Exception {
        var jwt = SignedJWT.parse(token);
        return jwt.getJWTClaimsSet().toJSONObject();
    }

    @SuppressWarnings("unchecked")
    private static void printClaims(Map<String, Object> claims, String clientId) {
        System.out.println("=== Key claims for Neo4j OIDC integration ===");
        System.out.println("  Issuer (iss):           " + claims.get("iss"));
        System.out.println("  Subject (sub):          " + claims.get("sub"));
        System.out.println("  Authorized party (azp): " + claims.get("azp"));

        // Audience validation — Neo4j's dbms.security.oidc.m2m.audience must match
        var aud = claims.get("aud");
        System.out.println("  Audience (aud):         " + aud);

        boolean audOk;
        if (aud instanceof List<?> audList) {
            audOk = audList.contains(clientId);
        } else {
            audOk = clientId.equals(aud);
        }
        if (audOk) {
            System.out.println("  Audience check:         PASS \u2014 contains '" + clientId + "'");
        } else {
            System.out.println("  Audience check:         FAIL \u2014 expected '" + clientId + "' in aud claim");
            System.out.println("                          Neo4j will reject this token. Add an audience");
            System.out.println("                          protocol mapper to the Keycloak client.");
        }

        // Top-level roles claim (via User Client Role protocol mapper)
        var topLevelRoles = claims.get("roles");
        System.out.println("  Roles (top-level):      " + topLevelRoles);
        if (topLevelRoles instanceof String) {
            System.out.println("  Roles type:             single string (supported by current Neo4j)");
        } else if (topLevelRoles instanceof List<?> rolesList) {
            System.out.println("  Roles type:             array (" + rolesList.size() + " entries)");
        } else if (topLevelRoles != null) {
            System.out.println("  Roles type:             WARNING \u2014 unexpected type: "
                    + topLevelRoles.getClass().getSimpleName());
        }

        // Also show native nested locations for reference
        if (claims.get("realm_access") instanceof Map<?, ?> realmAccess) {
            var realmRoles = realmAccess.get("roles");
            if (realmRoles instanceof List<?> rolesList && !rolesList.isEmpty()) {
                System.out.println("  realm_access.roles:     " + rolesList);
            }
        }

        if (claims.get("resource_access") instanceof Map<?, ?> resourceAccess) {
            for (var entry : resourceAccess.entrySet()) {
                if (entry.getValue() instanceof Map<?, ?> access) {
                    var clientRoles = access.get("roles");
                    if (clientRoles instanceof List<?> rolesList && !rolesList.isEmpty()) {
                        System.out.println("  resource_access." + entry.getKey() + ": " + rolesList);
                    }
                }
            }
        }

        if (claims.get("exp") instanceof Number exp) {
            System.out.println("  Expires (exp):          " + formatTimestamp(exp.longValue()));
        }
        if (claims.get("iat") instanceof Number iat) {
            System.out.println("  Issued at (iat):        " + formatTimestamp(iat.longValue()));
        }
        System.out.println();
    }

    private static String formatTimestamp(long epochSeconds) {
        return Instant.ofEpochSecond(epochSeconds)
                .atOffset(ZoneOffset.UTC)
                .format(DateTimeFormatter.ISO_OFFSET_DATE_TIME);
    }

    private static Map<String, String> loadEnvFile() {
        var envFile = Path.of(".env");
        var env = new HashMap<String, String>();
        if (!Files.exists(envFile)) {
            return env;
        }
        try {
            for (var line : Files.readAllLines(envFile)) {
                line = line.strip();
                if (line.isEmpty() || line.startsWith("#")) continue;
                var eq = line.indexOf('=');
                if (eq > 0) {
                    var key = line.substring(0, eq).strip();
                    var value = line.substring(eq + 1).strip();
                    // Strip surrounding quotes
                    if (value.length() >= 2
                            && ((value.startsWith("\"") && value.endsWith("\""))
                                || (value.startsWith("'") && value.endsWith("'")))) {
                        value = value.substring(1, value.length() - 1);
                    }
                    env.put(key, value);
                }
            }
        } catch (IOException e) {
            System.out.println("WARNING: Could not read .env file: " + e.getMessage());
        }
        return env;
    }

    private static void connectToNeo4j(String boltUri, String accessToken) {
        // Convert bolt:// to jdbc:neo4j://
        var jdbcUri = boltUri.replaceFirst("^bolt://", "jdbc:neo4j://")
                             .replaceFirst("^neo4j://", "jdbc:neo4j://");
        if (!jdbcUri.startsWith("jdbc:")) {
            jdbcUri = "jdbc:neo4j://" + jdbcUri;
        }

        System.out.println("=== Neo4j JDBC Connection (Bearer Auth) ===");
        System.out.println("JDBC URI: " + jdbcUri);
        System.out.println();

        var props = new Properties();
        props.put("authScheme", "bearer");
        props.put("password", accessToken);

        try (var conn = DriverManager.getConnection(jdbcUri, props);
             var stmt = conn.createStatement()) {

            System.out.println("Connected to Neo4j with bearer token.");
            System.out.println();

            // Verify current user and roles
            System.out.println("--- SHOW CURRENT USER ---");
            try (var rs = stmt.executeQuery("SHOW CURRENT USER YIELD user, roles")) {
                while (rs.next()) {
                    System.out.println("  User:  " + rs.getString("user"));
                    System.out.println("  Roles: " + rs.getObject("roles"));
                }
            }
            System.out.println();

            // Run a simple query
            System.out.println("--- Test query ---");
            try (var rs = stmt.executeQuery("RETURN 'Bearer auth works!' AS message, 1 AS result")) {
                while (rs.next()) {
                    System.out.println("  " + rs.getString("message") + " (result=" + rs.getInt("result") + ")");
                }
            }
            System.out.println();
            System.out.println("Neo4j JDBC bearer auth test PASSED.");

        } catch (SQLException e) {
            System.out.println("ERROR: Neo4j JDBC connection failed: " + e.getMessage());
            System.out.println();
            System.out.println("Troubleshooting:");
            System.out.println("  1. Is the Neo4j VM running and reachable?");
            System.out.println("  2. Is OIDC configured in neo4j.conf?");
            System.out.println("  3. Does the token audience match dbms.security.oidc.m2m.audience?");
            System.exit(1);
        }
    }

    private static class HttpErrorException extends Exception {
        final int statusCode;
        final String responseBody;

        HttpErrorException(int statusCode, String responseBody) {
            super("HTTP " + statusCode);
            this.statusCode = statusCode;
            this.responseBody = responseBody;
        }
    }
}
