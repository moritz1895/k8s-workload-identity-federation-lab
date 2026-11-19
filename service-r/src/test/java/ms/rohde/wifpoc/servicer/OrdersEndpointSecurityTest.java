package ms.rohde.wifpoc.servicer;

import static org.hamcrest.Matchers.containsString;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jose.jwk.source.ImmutableJWKSet;
import java.time.Instant;
import java.util.List;
import javax.crypto.spec.SecretKeySpec;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.security.oauth2.jose.jws.MacAlgorithm;
import org.springframework.security.oauth2.jose.jws.SignatureAlgorithm;
import org.springframework.security.oauth2.jwt.JwsHeader;
import org.springframework.security.oauth2.jwt.JwtClaimsSet;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtEncoderParameters;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.jwt.NimbusJwtEncoder;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.bean.override.convention.TestBean;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(OrdersController.class)
@Import(SecurityConfig.class)
@TestPropertySource(properties = {
        "service-r.issuer=" + OrdersEndpointSecurityTest.ISSUER,
        "service-r.audience=" + OrdersEndpointSecurityTest.AUDIENCE
})
class OrdersEndpointSecurityTest {

    static final String ISSUER = "https://keycloak:8443/realms/domain-rst";
    static final String AUDIENCE = "service-r";

    private static final String CLIENT_ID = "workload-a";
    private static final RSAKey REALM_KEY = generateKey("realm-kid");
    private static final RSAKey FOREIGN_KEY = generateKey("realm-kid");

    @TestBean
    private JwtDecoder jwtDecoder;

    @Autowired
    private MockMvc mvc;

    static JwtDecoder jwtDecoder() throws JOSEException {
        NimbusJwtDecoder decoder = NimbusJwtDecoder.withPublicKey(REALM_KEY.toRSAPublicKey()).build();
        decoder.setJwtValidator(AccessTokenValidators.forIssuerAndAudience(ISSUER, AUDIENCE));
        return decoder;
    }

    @Test
    void getOrders_givenReadScope_thenReturns200() throws Exception {
        mvc.perform(get("/orders").header("Authorization", bearer(token("r:orders:read"))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.clientId").value(CLIENT_ID))
                .andExpect(jsonPath("$.endpoint").value("GET /orders"))
                .andExpect(jsonPath("$.scopes[0]").value("r:orders:read"));
    }

    @Test
    void postOrders_givenWriteScope_thenReturns200() throws Exception {
        mvc.perform(post("/orders").header("Authorization", bearer(token("r:orders:read r:orders:write"))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.endpoint").value("POST /orders"));
    }

    @Test
    void postOrders_givenOnlyReadScope_thenReturns403() throws Exception {
        mvc.perform(post("/orders").header("Authorization", bearer(token("r:orders:read"))))
                .andExpect(status().isForbidden())
                .andExpect(header().string("WWW-Authenticate", containsString("insufficient_scope")));
    }

    @Test
    void deleteOrder_givenReadAndWriteScope_thenReturns403() throws Exception {
        mvc.perform(delete("/orders/1").header("Authorization", bearer(token("r:orders:read r:orders:write"))))
                .andExpect(status().isForbidden());
    }

    @Test
    void deleteOrder_givenAdminScope_thenReturns200() throws Exception {
        mvc.perform(delete("/orders/1").header("Authorization", bearer(token("r:orders:admin"))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.endpoint").value("DELETE /orders/1"));
    }

    @Test
    void getOrders_givenWrongAudience_thenReturns401() throws Exception {
        String token = sign(REALM_KEY, claims("r:orders:read").audience(List.of("service-s")).build());

        mvc.perform(get("/orders").header("Authorization", bearer(token)))
                .andExpect(status().isUnauthorized())
                .andExpect(header().string("WWW-Authenticate", containsString("invalid_token")));
    }

    @Test
    void getOrders_givenAudienceAsPlainString_thenReturns200() throws Exception {
        String token = sign(REALM_KEY, claims("r:orders:read").claim("aud", AUDIENCE).build());

        mvc.perform(get("/orders").header("Authorization", bearer(token)))
                .andExpect(status().isOk());
    }

    @Test
    void getOrders_givenTokenForSeveralAudiences_thenReturns401() throws Exception {
        String token = sign(REALM_KEY, claims("r:orders:read s:inventory:read")
                .audience(List.of(AUDIENCE, "service-s"))
                .build());

        mvc.perform(get("/orders").header("Authorization", bearer(token)))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void getOrders_givenIdTokenType_thenReturns401() throws Exception {
        String token = sign(REALM_KEY, claims("r:orders:read").claim("typ", "ID").build());

        mvc.perform(get("/orders").header("Authorization", bearer(token)))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void getOrders_givenNoClientId_thenReturns401() throws Exception {
        Instant now = Instant.now();
        String token = sign(REALM_KEY, JwtClaimsSet.builder()
                .issuer(ISSUER)
                .audience(List.of(AUDIENCE))
                .claim("typ", "Bearer")
                .claim("scope", "r:orders:read")
                .issuedAt(now)
                .expiresAt(now.plusSeconds(300))
                .build());

        mvc.perform(get("/orders").header("Authorization", bearer(token)))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void getOrders_givenHs256SignedWithRealmPublicKey_thenReturns401() throws Exception {
        byte[] publicKeyAsSecret = REALM_KEY.toRSAPublicKey().getEncoded();
        NimbusJwtEncoder encoder = NimbusJwtEncoder
                .withSecretKey(new SecretKeySpec(publicKeyAsSecret, "HmacSHA256"))
                .build();
        JwsHeader header = JwsHeader.with(MacAlgorithm.HS256).build();
        String token = encoder.encode(JwtEncoderParameters.from(header, claims("r:orders:read").build()))
                .getTokenValue();

        mvc.perform(get("/orders").header("Authorization", bearer(token)))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void getOrdersWithTrailingSlash_givenReadScope_thenReturns403() throws Exception {
        mvc.perform(get("/orders/").header("Authorization", bearer(token("r:orders:read"))))
                .andExpect(status().isForbidden());
    }

    @Test
    void getOrders_givenWrongIssuer_thenReturns401() throws Exception {
        String token = sign(REALM_KEY, claims("r:orders:read").issuer("https://issuer.wif.local").build());

        mvc.perform(get("/orders").header("Authorization", bearer(token)))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void getOrders_givenExpiredToken_thenReturns401() throws Exception {
        Instant past = Instant.now().minusSeconds(600);
        String token = sign(REALM_KEY, claims("r:orders:read")
                .issuedAt(past)
                .expiresAt(past.plusSeconds(300))
                .build());

        mvc.perform(get("/orders").header("Authorization", bearer(token)))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void getOrders_givenTamperedSignature_thenReturns401() throws Exception {
        mvc.perform(get("/orders").header("Authorization", bearer(tamperSignature(token("r:orders:read")))))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void getOrders_givenTokenSignedByForeignKey_thenReturns401() throws Exception {
        String token = sign(FOREIGN_KEY, claims("r:orders:read").build());

        mvc.perform(get("/orders").header("Authorization", bearer(token)))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void getOrders_givenNoToken_thenReturns401() throws Exception {
        mvc.perform(get("/orders"))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void unmappedPath_givenAllScopes_thenReturns403() throws Exception {
        mvc.perform(get("/admin").header("Authorization",
                        bearer(token("r:orders:read r:orders:write r:orders:admin"))))
                .andExpect(status().isForbidden());
    }

    private static String token(String scope) throws JOSEException {
        return sign(REALM_KEY, claims(scope).build());
    }

    private static JwtClaimsSet.Builder claims(String scope) {
        Instant now = Instant.now();
        return JwtClaimsSet.builder()
                .issuer(ISSUER)
                .audience(List.of(AUDIENCE))
                .claim("typ", "Bearer")
                .claim("azp", CLIENT_ID)
                .claim("scope", scope)
                .issuedAt(now)
                .expiresAt(now.plusSeconds(300));
    }

    private static String sign(RSAKey key, JwtClaimsSet claims) throws JOSEException {
        NimbusJwtEncoder encoder = new NimbusJwtEncoder(new ImmutableJWKSet<>(new JWKSet(key)));
        JwsHeader header = JwsHeader.with(SignatureAlgorithm.RS256).keyId(key.getKeyID()).build();
        return encoder.encode(JwtEncoderParameters.from(header, claims)).getTokenValue();
    }

    private static String tamperSignature(String token) {
        int signatureStart = token.lastIndexOf('.') + 1;
        char replacement = token.charAt(signatureStart) == 'A' ? 'B' : 'A';
        return token.substring(0, signatureStart) + replacement + token.substring(signatureStart + 1);
    }

    private static String bearer(String token) {
        return "Bearer " + token;
    }

    private static RSAKey generateKey(String keyId) {
        try {
            return new RSAKeyGenerator(2048).keyID(keyId).generate();
        } catch (JOSEException e) {
            throw new IllegalStateException(e);
        }
    }
}
