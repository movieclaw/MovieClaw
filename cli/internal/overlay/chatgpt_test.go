package overlay

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestChatGPTCallbackRejectsSpoofingAndReplay(t *testing.T) {
	callbacks := make(chan chatGPTCallback, 1)
	handler := chatGPTCallbackHandler("127.0.0.1:1455", "expected", callbacks)
	cases := []struct {
		address, host string
		status        int
	}{
		{"http://127.0.0.1:1455/auth/callback?state=wrong&code=secret", "127.0.0.1:1455", 400},
		{"http://127.0.0.1:1455/auth/callback?state=expected&code=secret", "evil.invalid", 400},
		{"http://127.0.0.1:1455/auth/callback?state=expected&state=other&code=secret", "127.0.0.1:1455", 400},
		{"http://127.0.0.1:1455/auth/callback?state=expected&code=secret&client_id=oaiapp_test", "127.0.0.1:1455", 200},
		{"http://127.0.0.1:1455/auth/callback?state=expected&code=secret", "127.0.0.1:1455", 409},
	}
	for _, c := range cases {
		request := httptest.NewRequest(http.MethodGet, c.address, nil)
		request.Host = c.host
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != c.status {
			t.Fatalf("status %d, want %d", response.Code, c.status)
		}
	}
	callback := <-callbacks
	if callback.Code != "secret" || callback.ClientID != "oaiapp_test" {
		t.Fatal("callback lost")
	}
}

func TestChatGPTDeclinedConsentDoesNotSupplyCode(t *testing.T) {
	callbacks := make(chan chatGPTCallback, 1)
	handler := chatGPTCallbackHandler("127.0.0.1:1455", "expected", callbacks)
	request := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:1455/auth/callback?state=expected&error=access_denied", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	callback := <-callbacks
	if callback.Err == nil || callback.Code != "" {
		t.Fatal("declined consent was accepted")
	}
}
