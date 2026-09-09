package ms.rohde.wifpoc;

import java.util.Map;
import org.jspecify.annotations.Nullable;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

@RestController
class TokenController {

    private static final String BEARER_PREFIX = "Bearer ";

    private final TokenValidator validator;

    TokenController(TokenValidator validator) {
        this.validator = validator;
    }

    @GetMapping("/healthz")
    Map<String, String> healthz() {
        return Map.of("status", "UP");
    }

    @GetMapping("/whoami")
    ResponseEntity<Map<String, Object>> whoami(
            @RequestHeader(name = "Authorization", required = false) @Nullable String authorization) {

        if (authorization == null || !authorization.startsWith(BEARER_PREFIX)) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED)
                    .body(Map.of("error", "missing_bearer_token"));
        }

        ValidationResult result = validator.validate(authorization.substring(BEARER_PREFIX.length()));
        Map<String, Object> claims = result.claims();
        if (!result.valid() || claims == null) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED)
                    .body(Map.of("error", "token_rejected", "reason", reasonOf(result)));
        }

        return ResponseEntity.ok(Map.of(
                "authenticated", Boolean.TRUE,
                "sub", claims.getOrDefault("sub", ""),
                "iss", claims.getOrDefault("iss", ""),
                "aud", claims.getOrDefault("aud", ""),
                "exp", claims.getOrDefault("exp", ""),
                "kubernetes.io", claims.getOrDefault("kubernetes.io", Map.of())));
    }

    private static String reasonOf(ValidationResult result) {
        String reason = result.reason();
        return reason == null ? "unknown" : reason;
    }
}
