//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Logging

/// A report generator for AWS dependency verification test results.
class AWSDependencyVerificationReport {
    
    // MARK: - Types
    
    /// A single test result entry
    struct ReportEntry {
        let name: String
        let category: ServiceCategory
        let success: Bool
        let duration: TimeInterval
        let error: Error?
        let details: [String: Any]
        let timestamp: Date
        
        var status: String {
            return success ? "✅ PASSED" : "❌ FAILED"
        }
    }
    
    /// Service categories for grouping results
    enum ServiceCategory: String {
        case cognito = "Authentication"
        case dynamodb = "Storage"
        case apiGateway = "API"
        case lambda = "Processing"
        case s3 = "Storage"
        case general = "General"
    }
    
    /// Report output format
    enum OutputFormat {
        case console
        case markdown
        case log
    }
    
    /// Report detail level
    enum DetailLevel {
        case summary
        case full
        case errorsOnly
    }
    
    // MARK: - Properties
    
    private let logger: Logger
    private var entries: [ReportEntry] = []
    private let startTime: Date
    private var previousReport: [ReportEntry]?
    
    // MARK: - Initialization
    
    init(logger: Logger = Logger(label: "org.signal.AWSDependencyVerificationReport")) {
        self.logger = logger
        self.startTime = Date()
    }
    
    // MARK: - Entry Management
    
    /// Adds a test result to the report
    func addEntry(_ name: String,
                 category: ServiceCategory,
                 success: Bool,
                 duration: TimeInterval,
                 error: Error? = nil,
                 details: [String: Any] = [:]) {
        let entry = ReportEntry(
            name: name,
            category: category,
            success: success,
            duration: duration,
            error: error,
            details: details,
            timestamp: Date()
        )
        entries.append(entry)
        
        // Log entry for immediate feedback
        if let error = error {
            logger.error("\(entry.status) - \(name): \(error.localizedDescription)")
        } else {
            logger.info("\(entry.status) - \(name) (\(String(format: "%.3f", duration))s)")
        }
    }
    
    /// Sets a previous report for comparison
    func setPreviousReport(_ entries: [ReportEntry]) {
        self.previousReport = entries
    }
    
    // MARK: - Report Generation
    
    /// Generates a formatted report
    func generateReport(format: OutputFormat = .log,
                      detailLevel: DetailLevel = .full) -> String {
        switch format {
        case .console:
            return generateConsoleReport(detailLevel: detailLevel)
        case .markdown:
            return generateMarkdownReport(detailLevel: detailLevel)
        case .log:
            return generateLogReport(detailLevel: detailLevel)
        }
    }
    
    private func generateConsoleReport(detailLevel: DetailLevel) -> String {
        var report = "AWS DEPENDENCY VERIFICATION REPORT\n"
        report += String(repeating: "=", count: 80) + "\n\n"
        
        // Add summary section
        report += generateSummarySection()
        
        if detailLevel != .summary {
            // Add detailed results by category
            for category in ServiceCategory.allCases {
                let categoryEntries = entries.filter { $0.category == category }
                if !categoryEntries.isEmpty {
                    report += "\n\(category.rawValue):\n"
                    report += String(repeating: "-", count: 40) + "\n"
                    
                    for entry in categoryEntries {
                        if detailLevel == .errorsOnly && entry.success {
                            continue
                        }
                        report += formatEntryForConsole(entry)
                    }
                }
            }
            
            // Add performance metrics
            report += "\nPERFORMANCE METRICS:\n"
            report += generatePerformanceMetrics()
        }
        
        return report
    }
    
    private func generateMarkdownReport(detailLevel: DetailLevel) -> String {
        var report = "# AWS Dependency Verification Report\n\n"
        
        // Add summary section
        report += "## Summary\n\n"
        report += generateSummarySection().replacingOccurrences(of: "\n", with: "  \n")
        
        if detailLevel != .summary {
            // Add detailed results by category
            for category in ServiceCategory.allCases {
                let categoryEntries = entries.filter { $0.category == category }
                if !categoryEntries.isEmpty {
                    report += "\n## \(category.rawValue)\n\n"
                    
                    for entry in categoryEntries {
                        if detailLevel == .errorsOnly && entry.success {
                            continue
                        }
                        report += formatEntryForMarkdown(entry)
                    }
                }
            }
            
            // Add comparison with previous run if available
            if let previousReport = previousReport {
                report += "\n## Comparison with Previous Run\n\n"
                report += generateComparisonSection(previousEntries: previousReport)
            }
            
            // Add performance metrics
            report += "\n## Performance Metrics\n\n"
            report += "```\n\(generatePerformanceMetrics())\n```\n"
        }
        
        return report
    }
    
    private func generateLogReport(detailLevel: DetailLevel) -> String {
        var report = "AWS DEPENDENCY VERIFICATION LOG\n"
        report += String(repeating: "=", count: 80) + "\n\n"
        report += "Timestamp: \(ISO8601DateFormatter().string(from: Date()))\n"
        report += "Test Duration: \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s\n\n"
        
        // Add results by category
        for category in ServiceCategory.allCases {
            let categoryEntries = entries.filter { $0.category == category }
            if !categoryEntries.isEmpty {
                report += "\(category.rawValue) VALIDATION\n"
                report += String(repeating: "-", count: 80) + "\n"
                
                for entry in categoryEntries {
                    if detailLevel == .errorsOnly && entry.success {
                        continue
                    }
                    report += formatEntryForLog(entry)
                }
                report += "\n"
            }
        }
        
        // Add performance metrics
        if detailLevel != .summary {
            report += "PERFORMANCE METRICS\n"
            report += String(repeating: "-", count: 80) + "\n"
            report += generatePerformanceMetrics()
        }
        
        return report
    }
    
    // MARK: - Helper Methods
    
    private func generateSummarySection() -> String {
        let total = entries.count
        let successful = entries.filter { $0.success }.count
        let failed = total - successful
        
        var summary = "Test Summary:\n"
        summary += "Total Tests: \(total)\n"
        summary += "Successful: \(successful)\n"
        summary += "Failed: \(failed)\n"
        summary += "Success Rate: \(String(format: "%.1f%%", Double(successful) / Double(total) * 100.0))\n"
        summary += "Total Duration: \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s\n"
        
        return summary
    }
    
    private func generatePerformanceMetrics() -> String {
        var metrics = ""
        metrics += "Operation                 | Avg (ms) | Min (ms) | Max (ms) | Std Dev (ms)\n"
        metrics += String(repeating: "-", count: 80) + "\n"
        
        // Group entries by name for statistical analysis
        let groupedEntries = Dictionary(grouping: entries) { $0.name }
        
        for (name, group) in groupedEntries.sorted(by: { $0.key < $1.key }) {
            let durations = group.map { $0.duration * 1000 } // Convert to milliseconds
            let avg = durations.reduce(0.0, +) / Double(durations.count)
            let min = durations.min() ?? 0
            let max = durations.max() ?? 0
            let stdDev = calculateStandardDeviation(durations)
            
            metrics += String(format: "%-22s | %8.0f | %8.0f | %8.0f | %11.0f\n",
                            name, avg, min, max, stdDev)
        }
        
        return metrics
    }
    
    private func generateComparisonSection(previousEntries: [ReportEntry]) -> String {
        var comparison = "| Test | Current | Previous | Change |\n"
        comparison += "|------|----------|-----------|--------|\n"
        
        let currentByName = Dictionary(grouping: entries) { $0.name }
        let previousByName = Dictionary(grouping: previousEntries) { $0.name }
        
        let allNames = Set(currentByName.keys).union(previousByName.keys).sorted()
        
        for name in allNames {
            let currentDuration = currentByName[name]?.first?.duration ?? 0
            let previousDuration = previousByName[name]?.first?.duration ?? 0
            let change = ((currentDuration - previousDuration) / previousDuration) * 100
            
            comparison += String(format: "| %@ | %.3fs | %.3fs | %+.1f%% |\n",
                               name, currentDuration, previousDuration, change)
        }
        
        return comparison
    }
    
    private func formatEntryForConsole(_ entry: ReportEntry) -> String {
        var result = "\(entry.status) \(entry.name) (\(String(format: "%.3f", entry.duration))s)\n"
        
        if let error = entry.error {
            result += "  Error: \(error.localizedDescription)\n"
        }
        
        for (key, value) in entry.details {
            result += "  \(key): \(value)\n"
        }
        
        return result
    }
    
    private func formatEntryForMarkdown(_ entry: ReportEntry) -> String {
        var result = "### \(entry.name)\n\n"
        result += "- Status: \(entry.status)\n"
        result += "- Duration: \(String(format: "%.3f", entry.duration))s\n"
        
        if let error = entry.error {
            result += "- Error: \(error.localizedDescription)\n"
        }
        
        if !entry.details.isEmpty {
            result += "- Details:\n"
            for (key, value) in entry.details {
                result += "  - \(key): \(value)\n"
            }
        }
        
        result += "\n"
        return result
    }
    
    private func formatEntryForLog(_ entry: ReportEntry) -> String {
        var result = "[\(ISO8601DateFormatter().string(from: entry.timestamp))] \(entry.status)\n"
        result += "Test: \(entry.name)\n"
        result += "Duration: \(String(format: "%.3f", entry.duration))s\n"
        
        if let error = entry.error {
            result += "Error: \(error.localizedDescription)\n"
        }
        
        for (key, value) in entry.details {
            result += "\(key): \(value)\n"
        }
        
        result += "\n"
        return result
    }
    
    private func calculateStandardDeviation(_ values: [Double]) -> Double {
        let count = Double(values.count)
        guard count > 1 else { return 0 }
        
        let mean = values.reduce(0.0, +) / count
        let variance = values.reduce(0.0) { sum, value in
            sum + pow(value - mean, 2)
        } / (count - 1)
        
        return sqrt(variance)
    }
}

// MARK: - ServiceCategory Extension

extension AWSDependencyVerificationReport.ServiceCategory: CaseIterable {
    static var allCases: [AWSDependencyVerificationReport.ServiceCategory] {
        return [.cognito, .dynamodb, .apiGateway, .lambda, .s3, .general]
    }
}