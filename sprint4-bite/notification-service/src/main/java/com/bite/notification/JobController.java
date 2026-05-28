package com.bite.notification;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

@RestController
public class JobController {

    private final JobStore store;
    private final JobProcessor processor;

    public JobController(JobStore store, JobProcessor processor) {
        this.store = store;
        this.processor = processor;
    }

    @GetMapping("/health")
    public Map<String, String> health() {
        Map<String, String> body = new LinkedHashMap<>();
        body.put("status", "ok");
        body.put("service", "notification-service");
        return body;
    }

    @PostMapping("/jobs")
    public Map<String, String> createJob(@RequestBody JobRequest req) {
        Map<String, Object> initial = new LinkedHashMap<>();
        initial.put("status", "processing");
        initial.put("email", req.email());
        store.put(req.jobId(), initial);

        processor.processJob(req.jobId(), req.email(), req.company(), req.project());

        Map<String, String> response = new LinkedHashMap<>();
        response.put("job_id", req.jobId());
        response.put("status", "queued");
        response.put("message", "Analysis running in background");
        return response;
    }

    @GetMapping("/jobs/{jobId}")
    public Map<String, Object> getJob(@PathVariable String jobId) {
        Map<String, Object> job = store.get(jobId);
        if (job != null) {
            return job;
        }
        Map<String, Object> notFound = new LinkedHashMap<>();
        notFound.put("error", "job not found");
        return notFound;
    }
}
