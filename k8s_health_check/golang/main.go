package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/csv"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/xuri/excelize/v2"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

type Config struct {
	KubeConfig         string
	OutputFile         string
	NamespaceWhitelist []string
	NamespaceBlacklist []string
	VerifyURLs         bool
	InsecureTLS        bool
	ExportExcel        bool
	Concurrency        int
	Timeout            int // 超时时间（秒）
}

type HealthCheckURL struct {
	Namespace   string
	ServiceName string
	PodName     string
	URL         string
	Type        string // http, https, tcp, udp
	HealthPath  string // 健康检查路径
	PortName    string // 端口名称（用于解析实际端口号）
	PortNumber  int32  // 实际端口号
}

func main() {
	log.Println("Starting K8s Health Checker...")

	config := loadConfig()
	clientset, err := createK8sClient(config.KubeConfig)
	if err != nil {
		log.Fatalf("Failed to create Kubernetes client: %v", err)
	}

	urls, err := collectHealthCheckURLs(clientset, config)
	if err != nil {
		log.Fatalf("Failed to collect health check URLs: %v", err)
	}

	if err := writeURLsToFile(config.OutputFile, urls); err != nil {
		log.Fatalf("Failed to write URLs to file: %v", err)
	}

	log.Printf("Successfully collected %d health check URLs", len(urls))
	log.Printf("Results written to: %s", config.OutputFile)

	// If URL verification is enabled, run verification
	// Note: For *.svc.cluster.local URLs, verification should ideally be done within the cluster
	// This verification will work for Pod IPs and external URLs, but cluster DNS may not resolve outside the cluster
	if config.VerifyURLs {
		log.Println("Starting URL verification...")
		if err := runURLVerification(config.OutputFile, config.Concurrency); err != nil {
			log.Fatalf("URL verification failed: %v", err)
		}
		log.Println("URL verification completed successfully")

		// If Excel export is enabled, convert CSV to Excel
		if config.ExportExcel {
			verificationFile := config.OutputFile + ".verification"
			excelFile := config.OutputFile + ".verification.xlsx"
			log.Printf("Exporting verification results to Excel: %s", excelFile)
			if err := convertCSVToExcel(verificationFile, excelFile); err != nil {
				log.Printf("Warning: Failed to export to Excel: %v", err)
			} else {
				log.Printf("Successfully exported to Excel: %s", excelFile)
			}
		}
	}
}

func loadConfig() *Config {
	config := &Config{
		KubeConfig:  getEnv("KUBECONFIG", "/app/config/kubeconfig"),
		OutputFile:  getEnv("OUTPUT_FILE", "/app/output/health-check-urls"),
		VerifyURLs:  getEnv("VERIFY_URLS", "false") == "true",
		InsecureTLS: getEnv("INSECURE_TLS", "false") == "true",
		ExportExcel: getEnv("EXPORT_EXCEL", "false") == "true",
		Concurrency: 20, // 默认并发数
		Timeout:     5,  // 默认超时5秒
	}

	// Parse concurrency from environment
	if concStr := getEnv("CONCURRENCY", "20"); concStr != "" {
		if conc, err := fmt.Sscanf(concStr, "%d", &config.Concurrency); err == nil && conc == 1 {
			if config.Concurrency < 1 {
				config.Concurrency = 1
			} else if config.Concurrency > 100 {
				config.Concurrency = 100
			}
		}
	}

	// Parse timeout from environment
	if timeoutStr := getEnv("TIMEOUT", "5"); timeoutStr != "" {
		if timeout, err := fmt.Sscanf(timeoutStr, "%d", &config.Timeout); err == nil && timeout == 1 {
			if config.Timeout < 1 {
				config.Timeout = 1
			} else if config.Timeout > 60 {
				config.Timeout = 60
			}
		}
	}

	if whitelist := getEnv("NAMESPACE_WHITELIST", ""); whitelist != "" {
		config.NamespaceWhitelist = strings.Split(whitelist, ",")
	}

	if blacklist := getEnv("NAMESPACE_BLACKLIST", "kube-system,kube-public,kube-node-lease"); blacklist != "" {
		config.NamespaceBlacklist = strings.Split(blacklist, ",")
	}

	return config
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func createK8sClient(kubeconfig string) (*kubernetes.Clientset, error) {
	var config *rest.Config
	var err error

	// 优先使用 in-cluster 配置（Pod 内部运行）
	config, err = rest.InClusterConfig()
	if err != nil {
		// 如果不在集群内，则使用 kubeconfig 文件
		log.Printf("Not running in cluster, trying kubeconfig file: %s", kubeconfig)
		if kubeconfig == "" || !fileExists(kubeconfig) {
			return nil, fmt.Errorf("kubeconfig file not found and not running in cluster")
		}
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
		if err != nil {
			return nil, fmt.Errorf("failed to build config: %w", err)
		}
	} else {
		log.Printf("Using in-cluster configuration")
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create clientset: %w", err)
	}

	return clientset, nil
}

func fileExists(filename string) bool {
	_, err := os.Stat(filename)
	return err == nil
}

func collectHealthCheckURLs(clientset *kubernetes.Clientset, config *Config) ([]HealthCheckURL, error) {
	var allURLs []HealthCheckURL

	namespaces, err := getTargetNamespaces(clientset, config)
	if err != nil {
		return nil, fmt.Errorf("failed to get namespaces: %w", err)
	}

	log.Printf("Scanning %d namespaces...", len(namespaces))

	for _, ns := range namespaces {
		log.Printf("Processing namespace: %s", ns)

		urls, err := collectURLsFromNamespace(clientset, ns)
		if err != nil {
			log.Printf("Warning: failed to collect URLs from namespace %s: %v", ns, err)
			continue
		}

		allURLs = append(allURLs, urls...)
	}

	return allURLs, nil
}

func getTargetNamespaces(clientset *kubernetes.Clientset, config *Config) ([]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	nsList, err := clientset.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, err
	}

	var targetNamespaces []string

	for _, ns := range nsList.Items {
		name := ns.Name

		// Check whitelist
		if len(config.NamespaceWhitelist) > 0 {
			if !contains(config.NamespaceWhitelist, name) {
				continue
			}
		}

		// Check blacklist
		if contains(config.NamespaceBlacklist, name) {
			continue
		}

		targetNamespaces = append(targetNamespaces, name)
	}

	return targetNamespaces, nil
}

func collectURLsFromNamespace(clientset *kubernetes.Clientset, namespace string) ([]HealthCheckURL, error) {
	var urls []HealthCheckURL

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Get all pods in namespace
	pods, err := clientset.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, err
	}

	for _, pod := range pods.Items {
		podURLs := extractURLsFromPod(&pod)
		urls = append(urls, podURLs...)
	}

	// Get all services in namespace
	services, err := clientset.CoreV1().Services(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, err
	}

	for _, service := range services.Items {
		serviceURLs := extractURLsFromService(&service)
		urls = append(urls, serviceURLs...)
	}

	return urls, nil
}

func extractURLsFromPod(pod *corev1.Pod) []HealthCheckURL {
	var urls []HealthCheckURL

	// Skip pods that are not in Running phase
	// Only Running pods should have health checks performed
	if pod.Status.Phase != corev1.PodRunning {
		return urls
	}

	// Check pod annotations for health check paths
	healthPath := getHealthCheckPath(pod.Annotations)

	// Extract from readiness and liveness probes
	for _, container := range pod.Spec.Containers {
		// Check readiness probe
		if container.ReadinessProbe != nil {
			if url := extractURLFromProbe(pod, container.ReadinessProbe, healthPath); url != nil {
				urls = append(urls, *url)
			}
		}

		// Check liveness probe
		if container.LivenessProbe != nil {
			if url := extractURLFromProbe(pod, container.LivenessProbe, healthPath); url != nil {
				urls = append(urls, *url)
			}
		}
	}

	return urls
}

func extractURLFromProbe(pod *corev1.Pod, probe *corev1.Probe, defaultPath string) *HealthCheckURL {
	// Skip pods without IP addresses (not ready yet)
	if pod.Status.PodIP == "" {
		return nil
	}

	if probe.HTTPGet != nil {
		scheme := strings.ToLower(string(probe.HTTPGet.Scheme))
		if scheme == "" {
			scheme = "http"
		}

		path := probe.HTTPGet.Path
		if path == "" && defaultPath != "" {
			path = defaultPath
		}
		if path == "" {
			path = "/"
		}

		port := probe.HTTPGet.Port.String()

		// Use Pod IP directly since Pods don't have stable DNS names like Services
		// Note: This will only work for verification within the cluster
		return &HealthCheckURL{
			Namespace:  pod.Namespace,
			PodName:    pod.Name,
			URL:        fmt.Sprintf("%s://%s:%s%s", scheme, pod.Status.PodIP, port, path),
			Type:       scheme,
			HealthPath: path,
			PortName:   probe.HTTPGet.Port.String(),
		}
	}

	if probe.TCPSocket != nil {
		port := probe.TCPSocket.Port.String()
		return &HealthCheckURL{
			Namespace: pod.Namespace,
			PodName:   pod.Name,
			URL:       fmt.Sprintf("tcp://%s:%s", pod.Status.PodIP, port),
			Type:      "tcp",
			PortName:  probe.TCPSocket.Port.String(),
		}
	}

	return nil
}

func extractURLsFromService(service *corev1.Service) []HealthCheckURL {
	var urls []HealthCheckURL

	healthPath := getHealthCheckPath(service.Annotations)

	for _, port := range service.Spec.Ports {
		// Determine protocol based on port protocol field, port number, and name
		protocol := strings.ToLower(string(port.Protocol))
		if protocol == "" {
			protocol = "tcp" // Default Kubernetes protocol
		}

		// For TCP protocol, check if it's likely HTTP/HTTPS based on port and name
		if protocol == "tcp" {
			scheme := "http"
			path := healthPath

			// Determine if HTTPS based on port number or name
			if port.Port == 443 || strings.Contains(strings.ToLower(port.Name), "https") || strings.Contains(strings.ToLower(port.Name), "ssl") || strings.Contains(strings.ToLower(port.Name), "tls") {
				scheme = "https"
			}

			// Check if this looks like an HTTP service
			isHTTPLike := port.Port == 80 || port.Port == 443 || port.Port == 8080 || port.Port == 8443 ||
				strings.Contains(strings.ToLower(port.Name), "http") ||
				strings.Contains(strings.ToLower(port.Name), "web") ||
				strings.Contains(strings.ToLower(port.Name), "api") ||
				healthPath != "" // If health path is explicitly set, assume HTTP

			if isHTTPLike {
				// Only add path if explicitly configured
				if path == "" {
					path = "" // Don't assume /health
				}
				urls = append(urls, HealthCheckURL{
					Namespace:   service.Namespace,
					ServiceName: service.Name,
					URL:         fmt.Sprintf("%s://%s.%s.svc.cluster.local:%d%s", scheme, service.Name, service.Namespace, port.Port, path),
					Type:        scheme,
					HealthPath:  path,
					PortName:    port.Name,
					PortNumber:  port.Port,
				})
			} else {
				// Plain TCP service
				urls = append(urls, HealthCheckURL{
					Namespace:   service.Namespace,
					ServiceName: service.Name,
					URL:         fmt.Sprintf("tcp://%s.%s.svc.cluster.local:%d", service.Name, service.Namespace, port.Port),
					Type:        "tcp",
					PortName:    port.Name,
					PortNumber:  port.Port,
				})
			}
		} else if protocol == "udp" {
			// UDP service
			urls = append(urls, HealthCheckURL{
				Namespace:   service.Namespace,
				ServiceName: service.Name,
				URL:         fmt.Sprintf("udp://%s.%s.svc.cluster.local:%d", service.Name, service.Namespace, port.Port),
				Type:        "udp",
				PortName:    port.Name,
				PortNumber:  port.Port,
			})
		}
	}

	return urls
}

func getHealthCheckPath(annotations map[string]string) string {
	// Check common annotation keys for health check paths
	keys := []string{
		"health.check.path",
		"healthcheck.path",
		"prometheus.io/path",
	}

	for _, key := range keys {
		if path, ok := annotations[key]; ok && path != "" {
			return path
		}
	}

	return ""
}

func writeURLsToFile(filename string, urls []HealthCheckURL) error {
	// Ensure output directory exists
	dir := filepath.Dir(filename)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create output directory: %w", err)
	}

	file, err := os.Create(filename)
	if err != nil {
		return fmt.Errorf("failed to create output file: %w", err)
	}
	defer file.Close()

	// Write header
	if _, err := file.WriteString("# K8s Health Check URLs\n"); err != nil {
		return err
	}
	if _, err := file.WriteString(fmt.Sprintf("# Generated at: %s\n\n", time.Now().Format(time.RFC3339))); err != nil {
		return err
	}

	// Group by namespace
	namespaceMap := make(map[string][]HealthCheckURL)
	for _, url := range urls {
		namespaceMap[url.Namespace] = append(namespaceMap[url.Namespace], url)
	}

	// Write URLs grouped by namespace
	for ns, nsURLs := range namespaceMap {
		if _, err := file.WriteString(fmt.Sprintf("# Namespace: %s\n", ns)); err != nil {
			return err
		}

		for _, url := range nsURLs {
			if _, err := file.WriteString(url.URL + "\n"); err != nil {
				return err
			}
		}

		if _, err := file.WriteString("\n"); err != nil {
			return err
		}
	}

	return nil
}

func runURLVerification(outputFile string, concurrency int) error {
	// Note: URL verification should be done within the cluster for *.svc.cluster.local URLs
	// This function provides basic verification for external testing
	log.Println("Running URL verification...")
	log.Println("Warning: Verification of *.svc.cluster.local URLs will only work within the cluster")

	// Read URLs from file
	urls, err := readURLsFromFile(outputFile)
	if err != nil {
		return fmt.Errorf("failed to read URLs from file: %w", err)
	}

	if len(urls) == 0 {
		log.Println("No URLs to verify")
		return nil
	}

	// Create verification results file
	resultsFile := outputFile + ".verification"
	file, err := os.Create(resultsFile)
	if err != nil {
		return fmt.Errorf("failed to create results file: %w", err)
	}
	defer file.Close()

	// Create CSV writer
	csvWriter := csv.NewWriter(file)
	defer csvWriter.Flush()

	// Write CSV header
	csvWriter.Write([]string{"URL", "Namespace", "ServiceName", "PodName", "Type", "Accessible", "StatusCode", "Error"})

	// Verify URLs with concurrency
	total := len(urls)
	accessible := verifyURLsConcurrently(urls, csvWriter, concurrency)

	log.Printf("Verification completed. %d/%d URLs are accessible", accessible, total)
	return nil
}

func readURLsFromFile(filename string) ([]HealthCheckURL, error) {
	file, err := os.Open(filename)
	if err != nil {
		return nil, fmt.Errorf("failed to open file: %w", err)
	}
	defer file.Close()

	var urls []HealthCheckURL
	scanner := bufio.NewScanner(file)
	currentNamespace := ""

	// Parse the file format which groups URLs by namespace
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		// Skip empty lines
		if line == "" {
			continue
		}

		// Check for namespace header
		if strings.HasPrefix(line, "# Namespace: ") {
			currentNamespace = strings.TrimPrefix(line, "# Namespace: ")
			continue
		}

		// Skip other comment lines
		if strings.HasPrefix(line, "#") {
			continue
		}

		// Parse URL line
		if line != "" {
			healthURL := HealthCheckURL{
				URL:       line,
				Namespace: currentNamespace,
			}

			// Determine type from URL
			if strings.HasPrefix(line, "https://") {
				healthURL.Type = "https"
			} else if strings.HasPrefix(line, "http://") {
				healthURL.Type = "http"
			} else if strings.HasPrefix(line, "tcp://") {
				healthURL.Type = "tcp"
			} else if strings.HasPrefix(line, "udp://") {
				healthURL.Type = "udp"
			}

			// Extract service name from URL if it's a service URL
			if strings.Contains(line, ".svc.cluster.local") {
				// Extract service name from URL like http://service-name.namespace.svc.cluster.local:port/path
				parts := strings.Split(line, "://")
				if len(parts) == 2 {
					hostPart := strings.Split(parts[1], "/")[0] // Remove path
					hostPart = strings.Split(hostPart, ":")[0]  // Remove port
					domainParts := strings.Split(hostPart, ".")
					if len(domainParts) >= 1 {
						healthURL.ServiceName = domainParts[0]
					}
				}
			}

			urls = append(urls, healthURL)
		}
	}

	return urls, scanner.Err()
}

// VerificationResult holds the result of a URL verification
type VerificationResult struct {
	HealthURL  HealthCheckURL
	Accessible bool
	StatusCode int
	Error      string
	Index      int
}

// verifyURLsConcurrently verifies URLs with concurrency control
func verifyURLsConcurrently(urls []HealthCheckURL, csvWriter *csv.Writer, concurrency int) int {
	total := len(urls)
	if concurrency < 1 {
		concurrency = 20 // 默认并发数
	}

	log.Printf("Starting verification with concurrency: %d", concurrency)

	// Create channels
	jobs := make(chan HealthCheckURL, total)
	results := make(chan VerificationResult, total)

	// Start worker pool
	for w := 0; w < concurrency; w++ {
		go func() {
			for healthURL := range jobs {
				accessible, statusCode, errMsg := verifySingleURL(healthURL.URL)
				results <- VerificationResult{
					HealthURL:  healthURL,
					Accessible: accessible,
					StatusCode: statusCode,
					Error:      errMsg,
				}
			}
		}()
	}

	// Send jobs
	go func() {
		for _, url := range urls {
			jobs <- url
		}
		close(jobs)
	}()

	// Collect results
	accessible := 0
	processed := 0
	resultMap := make(map[string]VerificationResult)

	for i := 0; i < total; i++ {
		result := <-results
		processed++

		if result.Accessible {
			accessible++
		}

		// Store result by URL for ordered output
		resultMap[result.HealthURL.URL] = result

		// Log progress every 50 URLs or at milestones
		if processed%50 == 0 || processed == total {
			log.Printf("Progress: %d/%d verified (%d accessible)", processed, total, accessible)
		}
	}
	close(results)

	// Write results in original order
	for _, healthURL := range urls {
		result := resultMap[healthURL.URL]
		csvWriter.Write([]string{
			result.HealthURL.URL,
			result.HealthURL.Namespace,
			result.HealthURL.ServiceName,
			result.HealthURL.PodName,
			result.HealthURL.Type,
			fmt.Sprintf("%t", result.Accessible),
			fmt.Sprintf("%d", result.StatusCode),
			result.Error,
		})
	}

	return accessible
}

func verifySingleURL(rawURL string) (bool, int, string) {
	// Get timeout from environment (default 5 seconds)
	timeoutSec := 5
	if timeoutStr := os.Getenv("TIMEOUT"); timeoutStr != "" {
		if t, err := fmt.Sscanf(timeoutStr, "%d", &timeoutSec); err == nil && t == 1 {
			if timeoutSec < 1 {
				timeoutSec = 1
			} else if timeoutSec > 60 {
				timeoutSec = 60
			}
		}
	}
	timeout := time.Duration(timeoutSec) * time.Second

	// Get TLS configuration from environment
	insecureTLS := os.Getenv("INSECURE_TLS") == "true"

	// Parse URL to determine protocol
	if strings.HasPrefix(rawURL, "tcp://") {
		return verifyTCPURL(rawURL, timeout)
	} else if strings.HasPrefix(rawURL, "http://") || strings.HasPrefix(rawURL, "https://") {
		return verifyHTTPURL(rawURL, timeout, insecureTLS)
	} else if strings.HasPrefix(rawURL, "udp://") {
		return verifyUDPURL(rawURL, timeout)
	} else {
		return false, 0, "Unsupported protocol"
	}
}

func verifyTCPURL(rawURL string, timeout time.Duration) (bool, int, string) {
	// Extract host and port from tcp://host:port
	url := strings.TrimPrefix(rawURL, "tcp://")
	parts := strings.Split(url, ":")
	if len(parts) != 2 {
		return false, 0, "Invalid TCP URL format"
	}

	host := parts[0]
	port := parts[1]

	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, port), timeout)
	if err != nil {
		return false, 0, err.Error()
	}
	conn.Close()
	return true, 0, ""
}

func verifyUDPURL(rawURL string, timeout time.Duration) (bool, int, string) {
	// Extract host and port from udp://host:port
	url := strings.TrimPrefix(rawURL, "udp://")
	parts := strings.Split(url, ":")
	if len(parts) != 2 {
		return false, 0, "Invalid UDP URL format"
	}

	host := parts[0]
	port := parts[1]

	// UDP is connectionless, so we can only check if we can create a connection
	// We cannot reliably verify if the service is actually listening
	conn, err := net.DialTimeout("udp", net.JoinHostPort(host, port), timeout)
	if err != nil {
		return false, 0, err.Error()
	}
	defer conn.Close()

	// Try to send a small packet and wait for response (optional)
	// Note: This is a basic check and may not work for all UDP services
	conn.SetDeadline(time.Now().Add(timeout))
	_, err = conn.Write([]byte("ping"))
	if err != nil {
		// Write error doesn't necessarily mean the service is down
		// UDP is connectionless, so we consider it accessible if we can dial
		return true, 0, ""
	}

	// Try to read response (optional, many UDP services won't respond to random data)
	buffer := make([]byte, 1024)
	_, err = conn.Read(buffer)
	if err != nil {
		// No response is common for UDP, still consider it accessible
		return true, 0, ""
	}

	return true, 0, ""
}

func verifyHTTPURL(rawURL string, timeout time.Duration, insecureTLS bool) (bool, int, string) {
	client := &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: insecureTLS},
		},
	}

	resp, err := client.Get(rawURL)
	if err != nil {
		return false, 0, err.Error()
	}
	defer resp.Body.Close()

	// 判断HTTP状态码是否表示成功
	accessible := resp.StatusCode < 400
	errorMsg := ""
	if !accessible {
		errorMsg = fmt.Sprintf("HTTP %d %s", resp.StatusCode, http.StatusText(resp.StatusCode))
	}

	return accessible, resp.StatusCode, errorMsg
}

func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}

// convertCSVToExcel converts a CSV file to Excel format with formatting
func convertCSVToExcel(csvFile, excelFile string) error {
	// Open CSV file
	file, err := os.Open(csvFile)
	if err != nil {
		return fmt.Errorf("failed to open CSV file: %v", err)
	}
	defer file.Close()

	// Read CSV data
	reader := csv.NewReader(file)
	reader.LazyQuotes = true       // 允许不严格的引号
	reader.TrimLeadingSpace = true // 去除前导空格
	records, err := reader.ReadAll()
	if err != nil {
		return fmt.Errorf("failed to read CSV data: %v", err)
	}

	if len(records) == 0 {
		return fmt.Errorf("CSV file is empty")
	}

	// Create Excel file
	f := excelize.NewFile()
	defer func() {
		if err := f.Close(); err != nil {
			log.Printf("Error closing Excel file: %v", err)
		}
	}()

	sheetName := "Health Check Results"
	index, err := f.NewSheet(sheetName)
	if err != nil {
		return fmt.Errorf("failed to create sheet: %v", err)
	}

	// Set header style
	headerStyle, err := f.NewStyle(&excelize.Style{
		Font: &excelize.Font{
			Bold: true,
			Size: 12,
		},
		Fill: excelize.Fill{
			Type:    "pattern",
			Color:   []string{"#E6E6FA"},
			Pattern: 1,
		},
		Border: []excelize.Border{
			{Type: "left", Color: "000000", Style: 1},
			{Type: "top", Color: "000000", Style: 1},
			{Type: "bottom", Color: "000000", Style: 1},
			{Type: "right", Color: "000000", Style: 1},
		},
	})
	if err != nil {
		return fmt.Errorf("failed to create header style: %v", err)
	}

	// Set data style
	dataStyle, err := f.NewStyle(&excelize.Style{
		Border: []excelize.Border{
			{Type: "left", Color: "000000", Style: 1},
			{Type: "top", Color: "000000", Style: 1},
			{Type: "bottom", Color: "000000", Style: 1},
			{Type: "right", Color: "000000", Style: 1},
		},
		Alignment: &excelize.Alignment{
			Vertical: "center",
		},
	})
	if err != nil {
		return fmt.Errorf("failed to create data style: %v", err)
	}

	// Success/failure styles
	successStyle, err := f.NewStyle(&excelize.Style{
		Fill: excelize.Fill{
			Type:    "pattern",
			Color:   []string{"#90EE90"},
			Pattern: 1,
		},
		Border: []excelize.Border{
			{Type: "left", Color: "000000", Style: 1},
			{Type: "top", Color: "000000", Style: 1},
			{Type: "bottom", Color: "000000", Style: 1},
			{Type: "right", Color: "000000", Style: 1},
		},
	})
	if err != nil {
		return fmt.Errorf("failed to create success style: %v", err)
	}

	failStyle, err := f.NewStyle(&excelize.Style{
		Fill: excelize.Fill{
			Type:    "pattern",
			Color:   []string{"#FFB6C1"},
			Pattern: 1,
		},
		Border: []excelize.Border{
			{Type: "left", Color: "000000", Style: 1},
			{Type: "top", Color: "000000", Style: 1},
			{Type: "bottom", Color: "000000", Style: 1},
			{Type: "right", Color: "000000", Style: 1},
		},
	})
	if err != nil {
		return fmt.Errorf("failed to create fail style: %v", err)
	}

	// Write data
	for rowIndex, record := range records {
		for colIndex, value := range record {
			cell, err := excelize.CoordinatesToCellName(colIndex+1, rowIndex+1)
			if err != nil {
				return fmt.Errorf("failed to get cell name: %v", err)
			}

			// Set cell value
			f.SetCellValue(sheetName, cell, value)

			// Apply styles
			if rowIndex == 0 {
				// Header style
				f.SetCellStyle(sheetName, cell, cell, headerStyle)
			} else {
				// Data style
				if colIndex == 5 && len(record) > 5 { // Accessible column
					if strings.ToLower(value) == "true" {
						f.SetCellStyle(sheetName, cell, cell, successStyle)
					} else {
						f.SetCellStyle(sheetName, cell, cell, failStyle)
					}
				} else {
					f.SetCellStyle(sheetName, cell, cell, dataStyle)
				}
			}
		}
	}

	// Set column widths
	columnWidths := map[string]float64{
		"A": 60, // URL
		"B": 20, // Namespace
		"C": 30, // ServiceName
		"D": 20, // PodName
		"E": 10, // Type
		"F": 12, // Accessible
		"G": 12, // StatusCode
		"H": 50, // Error
	}

	for col, width := range columnWidths {
		f.SetColWidth(sheetName, col, col, width)
	}

	// Set active sheet
	f.SetActiveSheet(index)

	// Delete default Sheet1
	f.DeleteSheet("Sheet1")

	// Save file
	if err := f.SaveAs(excelFile); err != nil {
		return fmt.Errorf("failed to save Excel file: %v", err)
	}

	return nil
}
