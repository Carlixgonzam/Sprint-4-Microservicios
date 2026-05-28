package com.bite.notification;

import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;

import java.util.LinkedHashMap;
import java.util.Map;

@Service
public class JobProcessor {

    private final JobStore store;

    public JobProcessor(JobStore store) {
        this.store = store;
    }

    @Async
    public void processJob(String jobId, String email, String company, String project) {
        try {
            Thread.sleep(3000);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return;
        }
        Map<String, Object> done = new LinkedHashMap<>();
        done.put("status", "done");
        done.put("email", email);
        done.put("company", company);
        done.put("project", project);
        done.put("completed_at", System.currentTimeMillis() / 1000.0);
        done.put("message", "Analysis for " + company + "/" + project
                + " completed. Results sent to " + email + ".");
        store.put(jobId, done);
        System.out.println("[NOTIF] Job " + jobId + " done -> email enviado a " + email);
    }
}
