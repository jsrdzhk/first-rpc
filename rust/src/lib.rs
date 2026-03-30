pub mod cli;
pub mod generated {
    pub mod rpc {
        tonic::include_proto!("first_rpc.rpc");
    }
}
pub mod ops;
