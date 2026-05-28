package com.bite.notification;

import org.springframework.stereotype.Component;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

@Component
public class JobStore {
    private final Map<String, Map<String, Object>> jobs = new ConcurrentHashMap<>();

    public void put(String jobId, Map<String, Object> data) {
        jobs.put(jobId, data);
    }

    public Map<String, Object> get(String jobId) {
        return jobs.get(jobId);
    }
}
