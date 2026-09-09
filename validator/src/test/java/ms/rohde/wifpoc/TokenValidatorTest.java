package ms.rohde.wifpoc;

import static org.assertj.core.api.Assertions.assertThat;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jose.jwk.source.ImmutableJWKSet;
import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.proc.SecurityContext;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import java.time.Instant;
import java.util.Date;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

class TokenValidatorTest {

    private static final String ISSUER = "https://issuer-web";
    private static final String AUDIENCE = "wif-demo-validator";
    private static final String SUBJECT = "system:serviceaccount:wif-demo:consumer";

    private static RSAKey clusterSigningKey;
    private static RSAKey unknownKey;
    private static TokenValidator validator;

    @BeforeAll
    static void setUp() throws Exception {
        clusterSigningKey = new RSAKeyGenerator(2048).keyID("cluster-kid").generate();
        unknownKey = new RSAKeyGenerator(2048).keyID("rogue-kid").generate();
        JWKSource<SecurityContext> jwks = new ImmutableJWKSet<>(new JWKSet(clusterSigningKey.toPublicJWK()));
        validator = new TokenValidator(jwks, ISSUER, AUDIENCE);
    }

    @Test
    void validate_givenValidToken_thenOk() throws Exception {
        ValidationResult result = validator.validate(mint(clusterSigningKey, validClaims().build()));

        assertThat(result.valid()).isTrue();
        assertThat(result.claims()).containsEntry("sub", SUBJECT);
    }

    @Test
    void validate_givenWrongAudience_thenRejected() throws Exception {
        String token = mint(clusterSigningKey, validClaims().audience("someone-else").build());

        ValidationResult result = validator.validate(token);

        assertThat(result.valid()).isFalse();
        assertThat(result.reason()).containsIgnoringCase("aud");
    }

    @Test
    void validate_givenExpiredToken_thenRejected() throws Exception {
        Instant past = Instant.now().minusSeconds(3600);
        String token = mint(clusterSigningKey, validClaims()
                .issueTime(Date.from(past))
                .expirationTime(Date.from(past.plusSeconds(600)))
                .build());

        ValidationResult result = validator.validate(token);

        assertThat(result.valid()).isFalse();
        assertThat(result.reason()).containsIgnoringCase("expired");
    }

    @Test
    void validate_givenWrongIssuer_thenRejected() throws Exception {
        String token = mint(clusterSigningKey, validClaims().issuer("https://evil.example").build());

        ValidationResult result = validator.validate(token);

        assertThat(result.valid()).isFalse();
        assertThat(result.reason()).containsIgnoringCase("iss");
    }

    @Test
    void validate_givenUnknownSigningKey_thenRejected() throws Exception {
        String token = mint(unknownKey, validClaims().build());

        ValidationResult result = validator.validate(token);

        assertThat(result.valid()).isFalse();
    }

    @Test
    void validate_givenTamperedSignature_thenRejected() throws Exception {
        String good = mint(clusterSigningKey, validClaims().build());
        String tampered = good.substring(0, good.length() - 1) + (good.endsWith("A") ? "B" : "A");

        ValidationResult result = validator.validate(tampered);

        assertThat(result.valid()).isFalse();
    }

    @Test
    void validate_givenMalformedToken_thenRejected() {
        ValidationResult result = validator.validate("this.is.not-a-jwt");

        assertThat(result.valid()).isFalse();
    }

    private static JWTClaimsSet.Builder validClaims() {
        Instant now = Instant.now();
        return new JWTClaimsSet.Builder()
                .issuer(ISSUER)
                .audience(AUDIENCE)
                .subject(SUBJECT)
                .issueTime(Date.from(now))
                .notBeforeTime(Date.from(now))
                .expirationTime(Date.from(now.plusSeconds(600)));
    }

    private static String mint(RSAKey key, JWTClaimsSet claims) throws Exception {
        SignedJWT jwt = new SignedJWT(
                new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.getKeyID()).build(),
                claims);
        jwt.sign(new RSASSASigner(key));
        return jwt.serialize();
    }
}
