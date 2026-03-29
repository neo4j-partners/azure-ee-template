plugins {
    java
    application
}

group = "com.neo4j.keycloak"
version = "0.1.0"

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("com.fasterxml.jackson.core:jackson-databind:2.18.3")
    implementation("com.nimbusds:nimbus-jose-jwt:10.0.2")
    implementation("org.neo4j:neo4j-jdbc:6.3.1")
}

application {
    mainClass.set("com.neo4j.keycloak.KeycloakTestClient")
}
